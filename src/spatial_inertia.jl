immutable SpatialInertia{T}
    frame::CartesianFrame3D
    moment::Mat{3, 3, T}
    centerOfMass::Vec{3, T}
    mass::T
end

function transform{T}(inertia::SpatialInertia{T}, t::Transform3D{T})
    @assert t.from == inertia.frame

    function vector_to_skew_symmetric_squared(a::Vec{3, T})
        aSq = a .* a
        b11 = -aSq[2] - aSq[3]
        b12 = a[1] * a[2]
        b13 = a[1] * a[3]
        b22 = -aSq[1] - aSq[3]
        b23 = a[2] * a[3]
        b33 = -aSq[1] - aSq[2]
        return Mat((b11, b12, b13), (b12, b22, b23), (b13, b23, b33))
    end

    J = inertia.moment
    m = inertia.mass
    c = inertia.centerOfMass

    R = Mat(rotationmatrix(t.rot))
    p = t.trans

    cnew = R * (c * m)
    Jnew = vector_to_skew_symmetric_squared(cnew)
    cnew += m * p
    Jnew -= vector_to_skew_symmetric_squared(cnew)
    Jnew /= m
    Jnew += R * J * R'
    cnew /= m

    return SpatialInertia(frame, Jnew, cnew, m)
end

rand{T}(::Type{SpatialInertia{T}}, frame::CartesianFrame3D) = SpatialInertia(frame, rand(Mat{3, 3, T}), rand(Vec{3, T}), rand(T))