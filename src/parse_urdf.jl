function parse_scalar(::Type{T}, e::XMLElement, name::String) where {T}
    T(parse(attribute(e, name)))
end

function parse_scalar(::Type{T}, e::XMLElement, name::String, default::String) where {T}
    T(parse(e == nothing ? default : attribute(e, name)))
end

function parse_vector(::Type{T}, e::Union{XMLElement, Void}, name::String, default::String) where {T}
    usedefault = e == nothing || attribute(e, name) == nothing # TODO: better handling of required attributes
    [T(parse(str)) for str in split(usedefault ? default : attribute(e, name))]
end

function parse_inertia(::Type{T}, xml_inertia::XMLElement) where {T}
    ixx = parse_scalar(T, xml_inertia, "ixx", "0")
    ixy = parse_scalar(T, xml_inertia, "ixy", "0")
    ixz = parse_scalar(T, xml_inertia, "ixz", "0")
    iyy = parse_scalar(T, xml_inertia, "iyy", "0")
    iyz = parse_scalar(T, xml_inertia, "iyz", "0")
    izz = parse_scalar(T, xml_inertia, "izz", "0")
    @SMatrix [ixx ixy ixz; ixy iyy iyz; ixz iyz izz]
end

function parse_pose(::Type{T}, xml_pose::Void) where {T}
    rot = eye(RotMatrix3{T})
    trans = zero(SVector{3, T})
    rot, trans
end

function parse_pose(::Type{T}, xml_pose::XMLElement) where {T}
    rpy = RotXYZ(parse_vector(T, xml_pose, "rpy", "0 0 0")...)
    rot = RotMatrix(rpy)
    trans = SVector{3}(parse_vector(T, xml_pose, "xyz", "0 0 0"))
    rot, trans
end

function parse_joint_type(::Type{T}, xml_joint::XMLElement) where {T}
    joint_type = attribute(xml_joint, "type")
    if joint_type == "revolute" || joint_type == "continuous" # TODO: handle joint limits for revolute
        axis = SVector{3}(parse_vector(T, find_element(xml_joint, "axis"), "xyz", "1 0 0"))
        return Revolute(axis)
    elseif joint_type == "prismatic"
        axis = SVector{3}(parse_vector(T, find_element(xml_joint, "axis"), "xyz", "1 0 0"))
        return Prismatic(axis)
    elseif joint_type == "floating"
        return QuaternionFloating{T}()
    elseif joint_type == "fixed"
        return Fixed{T}()
    else
        error("joint type $joint_type not recognized")
    end
end

function parse_joint_bounds(jtype::JT, xml_joint::XMLElement) where {T, JT <: JointType{T}}
    position_bounds = fill(Bounds{T}(), num_positions(jtype))
    velocity_bounds = fill(Bounds{T}(), num_velocities(jtype))
    effort_bounds = fill(Bounds{T}(), num_velocities(jtype))
    for element in get_elements_by_tagname(xml_joint, "limit")
        if has_attribute(element, "lower")
            position_bounds .= Bounds.(parse_scalar(T, element, "lower"), upper.(position_bounds))
        end
        if has_attribute(element, "upper")
            position_bounds .= Bounds.(lower.(position_bounds), parse_scalar(T, element, "upper"))
        end
        if has_attribute(element, "velocity")
            v = parse_scalar(T, element, "velocity")
            velocity_bounds .= Bounds(-v, v)
        end
        if has_attribute(element, "effort")
            e = parse_scalar(T, element, "effort")
            effort_bounds .= Bounds(-e, e)
        end
    end
    position_bounds, velocity_bounds, effort_bounds
end

function parse_joint(::Type{T}, xml_joint::XMLElement) where {T}
    name = attribute(xml_joint, "name")
    joint_type = parse_joint_type(T, xml_joint)
    position_bounds, velocity_bounds, effort_bounds = parse_joint_bounds(joint_type, xml_joint)
    return Joint(name, joint_type; position_bounds=position_bounds, velocity_bounds=velocity_bounds, effort_bounds=effort_bounds)
end

function parse_inertia(::Type{T}, xml_inertial::XMLElement, frame::CartesianFrame3D) where {T}
    urdf_frame = CartesianFrame3D("inertia urdf helper")
    moment = parse_inertia(T, find_element(xml_inertial, "inertia"))
    com = zeros(SVector{3, T})
    mass = parse_scalar(T, find_element(xml_inertial, "mass"), "value", "0")
    inertia = SpatialInertia(urdf_frame, moment, com, mass)
    pose = parse_pose(T, find_element(xml_inertial, "origin"))
    transform(inertia, Transform3D(urdf_frame, frame, pose...))
end

function parse_body(::Type{T}, xml_link::XMLElement, frame::CartesianFrame3D = CartesianFrame3D(attribute(xml_link, "name"))) where {T}
    xml_inertial = find_element(xml_link, "inertial")
    inertia = xml_inertial == nothing ? zero(SpatialInertia{T}, frame) : parse_inertia(T, xml_inertial, frame)
    linkname = attribute(xml_link, "name") # TODO: make sure link name is unique
    RigidBody(linkname, inertia)
end

function parse_root_link(mechanism::Mechanism{T}, xml_link::XMLElement) where {T}
    parent = root_body(mechanism)
    body = parse_body(T, xml_link)
    joint = Joint("$(string(body))_to_world", Fixed{T}())
    joint_to_parent = eye(Transform3DS{T}, frame_before(joint), default_frame(parent))
    attach!(mechanism, parent, body, joint, joint_pose = joint_to_parent)
end

function parse_joint_and_link(mechanism::Mechanism{T}, xml_parent::XMLElement, xml_child::XMLElement, xml_joint::XMLElement) where {T}
    parentname = attribute(xml_parent, "name")
    candidate_parents = collect(filter(b -> string(b) == parentname, bodies(mechanism)))
    length(candidate_parents) == 1 || error("Duplicate name: $(parentname)")
    parent = first(candidate_parents)
    joint = parse_joint(T, xml_joint)
    pose = parse_pose(T, find_element(xml_joint, "origin"))
    joint_to_parent = Transform3D(frame_before(joint), default_frame(parent), pose...)
    body = parse_body(T, xml_child, frame_after(joint))
    attach!(mechanism, parent, body, joint, joint_pose = joint_to_parent)
end

"""
$(SIGNATURES)

Create a `Mechanism` by parsing a [URDF](http://wiki.ros.org/urdf) file.
"""
function parse_urdf(scalartype::Type{T}, filename) where {T}
    xdoc = parse_file(filename)
    xroot = LightXML.root(xdoc)
    @assert LightXML.name(xroot) == "robot"

    xml_links = get_elements_by_tagname(xroot, "link")
    xml_joints = get_elements_by_tagname(xroot, "joint")

    # create graph structure of XML elements
    graph = DirectedGraph{Vertex{XMLElement}, Edge{XMLElement}}()
    vertices = Vertex.(xml_links)
    for vertex in vertices
        add_vertex!(graph, vertex)
    end
    name_to_vertex = Dict(attribute(data(v), "name") => v for v in vertices)
    for xml_joint in xml_joints
        parent = name_to_vertex[attribute(find_element(xml_joint, "parent"), "link")]
        child = name_to_vertex[attribute(find_element(xml_joint, "child"), "link")]
        add_edge!(graph, parent, child, Edge(xml_joint))
    end

    # create a spanning tree
    roots = collect(filter(v -> isempty(in_edges(v, graph)), vertices))
    length(roots) != 1 && error("Can only handle a single root")
    tree = SpanningTree(graph, first(roots))

    # create mechanism from spanning tree
    rootbody = RigidBody{T}("world")
    mechanism = Mechanism(rootbody)
    parse_root_link(mechanism, data(Graphs.root(tree)))
    for edge in edges(tree)
        parse_joint_and_link(mechanism, data(source(edge, tree)), data(target(edge, tree)), data(edge))
    end
    mechanism
end
