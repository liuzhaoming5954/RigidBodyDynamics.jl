module CustomCollections

using TypeSortedCollections

export
    ConstVector,
    NullDict,
    UnsafeVectorView,
    UnsafeFastDict

export
    fastview,
    foreach_with_extra_args

## TypeSortedCollections addendum
# `foreach_with_extra_args` below is a hack to avoid allocations associated with creating closures over
# heap-allocated variables. Hopefully this will not be necessary in a future version of Julia.
for num_extra_args = 1 : 5
    extra_arg_syms = [Symbol("arg", i) for i = 1 : num_extra_args]
    @eval begin
        @generated function foreach_with_extra_args(f, $(extra_arg_syms...), A1::TypeSortedCollection{<:Any, N}, As::Union{<:TypeSortedCollection{<:Any, N}, AbstractVector}...) where {N}
            extra_args = $extra_arg_syms
            expr = Expr(:block)
            push!(expr.args, :(Base.@_inline_meta)) # required to achieve zero allocation
            push!(expr.args, :(leading_tsc = A1))
            push!(expr.args, :(@boundscheck TypeSortedCollections.lengths_match(A1, As...) || TypeSortedCollections.lengths_match_fail()))
            for i = 1 : N
                vali = Val(i)
                push!(expr.args, quote
                    let inds = leading_tsc.indices[$i]
                        @boundscheck TypeSortedCollections.indices_match($vali, inds, A1, As...) || TypeSortedCollections.indices_match_fail()
                        @inbounds for j in linearindices(inds)
                            vecindex = inds[j]
                            f($(extra_args...), TypeSortedCollections._getindex_all($vali, j, vecindex, A1, As...)...)
                        end
                    end
                end)
            end
            quote
                $expr
                nothing
            end
        end
    end
end


## ConstVector
"""
An immutable `AbstractVector` for which all elements are the same, represented
compactly and as an isbits type if the element type is `isbits`.
"""
struct ConstVector{T} <: AbstractVector{T}
    val::T
    length::Int64
end
Base.size(A::ConstVector) = (A.length, )
@inline Base.getindex(A::ConstVector, i::Int) = (@boundscheck checkbounds(A, i); A.val)
Base.IndexStyle(::Type{<:ConstVector}) = IndexLinear()


## NullDict
"""
An immutable associative type that signifies an empty dictionary and does not
allocate any memory.
"""
struct NullDict{K, V} <: Associative{K, V}
end
Base.haskey(::NullDict, k) = false


## UnsafeVectorView
"""
Views in Julia still allocate some memory (since they need to keep
a reference to the original array). This type allocates no memory
and does no bounds checking. Use it with caution.

Originally from https://github.com/mlubin/ReverseDiffSparse.jl/commit/8e3ade867581aad6ade7c898ada2ed58e0ad42bb.
"""
struct UnsafeVectorView{T} <: AbstractVector{T}
    offset::Int
    len::Int
    ptr::Ptr{T}
end

@inline UnsafeVectorView(parent::Union{Vector, Base.FastContiguousSubArray}, range::UnitRange) = UnsafeVectorView(start(range) - 1, length(range), pointer(parent))
@inline Base.size(v::UnsafeVectorView) = (v.len,)
@inline Base.getindex(v::UnsafeVectorView, idx::Int) = unsafe_load(v.ptr, idx + v.offset)
@inline Base.setindex!(v::UnsafeVectorView, value, idx::Int) = unsafe_store!(v.ptr, value, idx + v.offset)
@inline Base.length(v::UnsafeVectorView) = v.len
Base.IndexStyle(::Type{<:UnsafeVectorView}) = IndexLinear()

"""
UnsafeVectorView only works for isbits types. For other types, we're already
allocating lots of memory elsewhere, so creating a new SubArray is fine.
This function looks type-unstable, but the isbits(T) test can be evaluated
by the compiler, so the result is actually type-stable.

From https://github.com/rdeits/NNLS.jl/blob/0a9bf56774595b5735bc738723bd3cb94138c5bd/src/NNLS.jl#L218.
"""
@inline function fastview(parent::Union{Vector{T}, Base.FastContiguousSubArray{T}}, range::UnitRange) where {T}
    if isbits(T)
        UnsafeVectorView(parent, range)
    else
        view(parent, range)
    end
end


# UnsafeFastDict
struct UnsafeFastDict{I, K, V} <: Associative{K, V}
    keys::Vector{K}
    values::Vector{V}

    # specify index function, key type, and value type
    function UnsafeFastDict{I, K, V}(kv) where {I, K, V}
        keys = K[]
        values = V[]
        for (k, v) in kv
            index = I(k)
            if index > length(keys)
                resize!(keys, index)
                resize!(values, index)
            end
            keys[index] = k
            values[index] = v
        end
        new(keys, values)
    end

    # infer value type
    function UnsafeFastDict{I, K}(kv) where {I, K}
        T = Core.Inference.return_type(first, Tuple{typeof(kv)})
        V = Core.Inference.return_type(last, Tuple{T})
        UnsafeFastDict{I, K, V}(kv)
    end

    # infer key type and value type
    function UnsafeFastDict{I}(kv) where {I}
        T = Core.Inference.return_type(first, Tuple{typeof(kv)})
        K = Core.Inference.return_type(first, Tuple{T})
        V = Core.Inference.return_type(last, Tuple{T})
        UnsafeFastDict{I, K, V}(kv)
    end

    # specify all types, but leave values uninitialized
    function UnsafeFastDict{I, K, V}(keys::AbstractVector{K}) where {I, K, V}
        sortedkeys = K[]
        for k in keys
            index = I(k)
            if index > length(sortedkeys)
                resize!(sortedkeys, index)
            end
            sortedkeys[index] = k
        end
        values = Vector{V}(length(sortedkeys))
        new(sortedkeys, values)
    end
end

# Iteration
@inline Base.start(d::UnsafeFastDict) = 1
@inline Base.done(d::UnsafeFastDict, state) = state > length(d)
@inline Base.next(d::UnsafeFastDict, state) = (d.keys[state] => d.values[state], state + 1)

# Associative
@inline Base.length(d::UnsafeFastDict) = length(d.values)
@inline Base.haskey(d::UnsafeFastDict{I, K, V}, key) where {I, K, V} = (1 <= I(key) <= length(d)) && (@inbounds return d.keys[I(key)] === key)
@inline Base.getindex(d::UnsafeFastDict, key) = get(d, key)
@inline Base.get(d::UnsafeFastDict{I, K, V}, key) where {I, K, V} = d.values[I(key)]
@inline Base.keys(d::UnsafeFastDict) = d.keys
@inline Base.values(d::UnsafeFastDict) = d.values
@inline Base.setindex!(d::UnsafeFastDict{I, K, V}, value::V, key) where {I, K, V} = (d.values[I(key)] = value)

end # module
