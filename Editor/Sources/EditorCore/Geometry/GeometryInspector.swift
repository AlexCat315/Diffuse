import AssetPipeline
import CoveUIRuntime
import Foundation
import SIMDCompat

extension EditorGeometryAuthoring {
    public func inspectorSections(for entityID: UInt64) -> [EditorInspectorSection] {
        do {
            guard let document = try document(for: entityID) else { return [] }
            var source = sourceFields(document.source, entityID: entityID)
            source.insert(field("geometry-shading", "Shading", .stringOptions(
                binding(entityID, fallback: document.shading.rawValue, get: { $0.shading.rawValue }, set: { doc, value in
                    guard let shading = GeometryShading(rawValue: value) else { throw GeometryError.invalidParameter("shading") }
                    doc.shading = shading
                }), options: [option("flat","Flat"),option("smooth","Smooth")])), at: 0)
            source.insert(field("geometry-file", "Asset", .readOnly(document.name)), at: 0)
            source.append(action("geometry-convert", "Topology", "Convert Source to Mesh") { [weak self] in
                _ = self?.edit(entityID: entityID) { $0.source = .polygon(mesh: try $0.source.evaluate()) }
            })
            var sections = [section("geometry-source", "Geometry", source)]
            for (index, entry) in document.modifiers.enumerated() {
                let id = entry.id
                var fields = [field("\(id)-enabled", "Enabled", .bool(binding(entityID, fallback: entry.enabled,
                    get: { $0.modifiers.first { $0.id == id }?.enabled ?? false }, set: { doc, enabled in
                        guard let i = doc.modifiers.firstIndex(where: { $0.id == id }) else { return }
                        doc.modifiers[i].enabled = enabled
                    })))]
                fields += modifierFields(entry, entityID: entityID)
                if index > 0 {
                    fields.append(action("\(id)-up", "Order", "Move Up") { [weak self] in
                        _ = self?.moveModifier(id, by: -1, on: entityID)
                    })
                }
                if index < document.modifiers.count - 1 {
                    fields.append(action("\(id)-down", "Order", "Move Down") { [weak self] in
                        _ = self?.moveModifier(id, by: 1, on: entityID)
                    })
                }
                fields.append(action("\(id)-apply", "Topology", "Apply Through Modifier") { [weak self] in
                    _ = self?.applyModifier(id, on: entityID)
                })
                fields.append(action("\(id)-remove", "Modifier", "Remove", destructive: true) { [weak self] in
                    _ = self?.removeModifier(id, from: entityID)
                })
                sections.append(section("geometry-modifier-\(id)", "\(index + 1). \(modifierName(entry.operation))", fields))
            }
            let defaults: [(String, GeometryModifier)] = [("Mirror",.mirror(axis: .x, offset: 0, weldDistance: 0.00001)),
                ("Array",.array(count: 2, offset: SIMD3(1.5,0,0))), ("Subdivision",.subdivision(levels: 1)),
                ("Solidify",.solidify(thickness: 0.1))]
            sections.append(section("geometry-modifiers", "Add Modifier", defaults.map { name, operation in
                action("geometry-add-\(name.lowercased())", name, "Add") { [weak self] in
                    _ = self?.addModifier(operation, to: entityID)
                }
            }))
            for index in document.materials.indices {
                let material = document.materials[index]
                sections.append(section("geometry-material-\(index)", "\(L("Material")) \(index + 1)", [
                    field("geometry-material-\(index)-name", "Name", .text(binding(entityID, fallback: material.name,
                        get: { $0.materials.indices.contains(index) ? $0.materials[index].name : "" },
                        set: { doc,value in if doc.materials.indices.contains(index) { doc.materials[index].name = value } }))),
                    field("geometry-material-\(index)-color", "Base Color", .color(binding(entityID,
                        fallback: Color(r: material.baseColor.x,g: material.baseColor.y,b: material.baseColor.z,a: material.baseColor.w),
                        get: { doc in
                            guard doc.materials.indices.contains(index) else { return .white }
                            let c = doc.materials[index].baseColor
                            return Color(r: c.x,g: c.y,b: c.z,a: c.w)
                        }, set: { doc,c in
                            if doc.materials.indices.contains(index) { doc.materials[index].baseColor = SIMD4(c.r,c.g,c.b,c.a) }
                        }))),
                    number("geometry-material-\(index)-metallic", "Metallic", binding(entityID, fallback: material.metallic,
                        get: { $0.materials.indices.contains(index) ? $0.materials[index].metallic : 0 },
                        set: { doc,v in if doc.materials.indices.contains(index) { doc.materials[index].metallic = v } }), min: 0, max: 1),
                    number("geometry-material-\(index)-roughness", "Roughness", binding(entityID, fallback: material.roughness,
                        get: { $0.materials.indices.contains(index) ? $0.materials[index].roughness : 0.5 },
                        set: { doc,v in if doc.materials.indices.contains(index) { doc.materials[index].roughness = v } }), min: 0, max: 1),
                ]))
            }
            return sections
        } catch {
            return [section("geometry-error", "Geometry", [field("geometry-error", "Source", .readOnly(String(describing: error)))])]
        }
    }

    @discardableResult
    public func applyModifier(_ id: String, on entityID: UInt64) -> Bool {
        edit(entityID: entityID) { document in
            guard let index = document.modifiers.firstIndex(where: { $0.id == id }) else {
                throw GeometryError.invalidParameter("missing modifier")
            }
            var mesh = try document.source.evaluate()
            for entry in document.modifiers[...index] where entry.enabled { mesh = try entry.operation.apply(to: mesh) }
            document.source = .polygon(mesh: mesh)
            document.modifiers.removeFirst(index + 1)
        }
    }
}

private extension EditorGeometryAuthoring {
    func section(_ id: String, _ title: String, _ fields: [EditorInspectorField]) -> EditorInspectorSection {
        var section = EditorInspectorSection(id: id,title: L(title),fields: fields)
        section.supportsMultiSelection = false
        return section
    }

    func field(_ id: String, _ label: String, _ value: EditorInspectorFieldValue) -> EditorInspectorField {
        EditorInspectorField(id: id,label: L(label),value: value)
    }

    func option(_ value: String, _ label: String) -> EditorInspectorStringOption { .init(value: value,label: L(label)) }

    func action(_ id: String, _ label: String, _ title: String, destructive: Bool = false,
                _ callback: @escaping () -> Void) -> EditorInspectorField {
        field(id,label,.action(title: L(title),isDestructive: destructive,action: callback))
    }

    func number(_ id: String, _ label: String, _ value: Binding<Float>, min: Float? = nil,
                max: Float? = nil, step: Float? = nil) -> EditorInspectorField {
        field(id,label,.constrainedNumber(value,min: min,max: max,step: step,showsStepper: true))
    }

    func binding<T>(_ entityID: UInt64, fallback: T, get: @escaping (GeometryDocument) -> T,
                    set: @escaping (inout GeometryDocument,T) throws -> Void) -> Binding<T> {
        Binding(get: { [weak self] in
            guard let document = try? self?.document(for: entityID) else { return fallback }
            return get(document)
        }, set: { [weak self] value in _ = self?.edit(entityID: entityID) { try set(&$0,value) } })
    }

    func vector(_ id: String, _ label: String, entityID: UInt64, fallback: SIMD3<Float>,
                get: @escaping (GeometryDocument) -> SIMD3<Float>,
                set: @escaping (inout GeometryDocument,SIMD3<Float>) throws -> Void) -> EditorInspectorField {
        func axis(_ index: Int) -> Binding<Float> {
            binding(entityID,fallback: fallback[index],get: { get($0)[index] },set: { doc,value in
                var v = get(doc); v[index] = value; try set(&doc,v)
            })
        }
        return field(id,label,.vector3(x: axis(0),y: axis(1),z: axis(2)))
    }

    func integer(_ value: Float, _ range: ClosedRange<Int>) throws -> Int {
        guard value.isFinite, value >= Float(range.lowerBound), value <= Float(range.upperBound) else {
            throw GeometryError.invalidParameter("integer parameter")
        }
        return Int(value.rounded())
    }

    func sourceFields(_ source: GeometrySource, entityID: UInt64) -> [EditorInspectorField] {
        switch source {
        case let .box(size):
            return [vector("geometry-size","Size",entityID: entityID,fallback: size,
                get: { if case let .box(size) = $0.source { return size }; return .one },
                set: { if case .box = $0.source { $0.source = .box(size: $1) } })]
        case let .grid(size,segments):
            return (0..<2).flatMap { axis -> [EditorInspectorField] in
                [number("geometry-grid-size-\(axis)",axis == 0 ? "Width" : "Depth",binding(entityID,fallback: size[axis],
                    get: { if case let .grid(size,_) = $0.source { return size[axis] }; return 1 },
                    set: { doc,v in if case let .grid(size,s) = doc.source { var size = size; size[axis] = v; doc.source = .grid(size: size,segments: s) } }),min: 0.0001),
                 number("geometry-grid-segments-\(axis)",axis == 0 ? "Columns" : "Rows",binding(entityID,fallback: Float(segments[axis]),
                    get: { if case let .grid(_,s) = $0.source { return Float(s[axis]) }; return 1 },
                    set: { [self] doc,v in if case let .grid(size,s) = doc.source {
                        var s = s; s[axis] = try integer(v,1...1024); doc.source = .grid(size: size,segments: s)
                    } }),min: 1,max: 1024,step: 1)]
            }
        case let .polygon(mesh):
            return [field("geometry-vertices","Vertices",.readOnly(String(mesh.positions.count))),
                    field("geometry-faces","Faces",.readOnly(String(mesh.faces.count)))]
        case let .tube(spline,radius,radial,samples,capped):
            func curveBinding<T>(_ fallback: T, get: @escaping (BezierSpline,Float,Int,Int,Bool) -> T,
                                 set: @escaping (inout BezierSpline,inout Float,inout Int,inout Int,inout Bool,T) throws -> Void) -> Binding<T> {
                binding(entityID,fallback: fallback,get: {
                    if case let .tube(s,r,n,c,b) = $0.source { return get(s,r,n,c,b) }; return fallback
                },set: { doc,value in
                    if case var .tube(s,r,n,c,b) = doc.source {
                        try set(&s,&r,&n,&c,&b,value)
                        doc.source = .tube(spline: s,radius: r,radialSegments: n,samplesPerSegment: c,capped: b)
                    }
                })
            }
            var fields = [
                number("geometry-tube-radius","Radius",curveBinding(radius,get: { _,r,_,_,_ in r },set: { _,r,_,_,_,v in r = v }),min: 0.0001),
                number("geometry-tube-radial","Sides",curveBinding(Float(radial),get: { _,_,n,_,_ in Float(n) },
                    set: { [self] _,_,n,_,_,v in n = try integer(v,3...256) }),min: 3,max: 256,step: 1),
                number("geometry-tube-samples","Resolution",curveBinding(Float(samples),get: { _,_,_,n,_ in Float(n) },
                    set: { [self] _,_,_,n,_,v in n = try integer(v,1...4096) }),min: 1,max: 4096,step: 1),
                field("geometry-tube-capped","Caps",.bool(curveBinding(capped,get: { _,_,_,_,b in b },set: { _,_,_,_,b,v in b = v }))),
                field("geometry-tube-closed","Closed",.bool(curveBinding(spline.closed,get: { s,_,_,_,_ in s.closed },set: { s,_,_,_,_,v in s.closed = v }))),
            ]
            for i in spline.points.indices {
                let properties: [(String,WritableKeyPath<BezierControlPoint,SIMD3<Float>>)] = [("Position",\.position),("Handle In",\.handleIn),("Handle Out",\.handleOut)]
                for (label,path) in properties {
                    fields.append(vector("geometry-point-\(i)-\(label)","\(i + 1) \(L(label))",entityID: entityID,
                        fallback: spline.points[i][keyPath: path],get: { doc in
                            if case let .tube(s,_,_,_,_) = doc.source, s.points.indices.contains(i) { return s.points[i][keyPath: path] }
                            return .zero
                        },set: { doc,v in
                            if case let .tube(s,r,n,c,b) = doc.source, s.points.indices.contains(i) {
                                var spline = s
                                spline.points[i][keyPath: path] = v
                                doc.source = .tube(spline: spline,radius: r,radialSegments: n,samplesPerSegment: c,capped: b)
                            }
                        }))
                }
            }
            return fields
        }
    }

    func modifierName(_ operation: GeometryModifier) -> String {
        switch operation { case .mirror: L("Mirror"); case .array: L("Array"); case .subdivision: L("Subdivision"); case .solidify: L("Solidify") }
    }

    func modifierBinding<T>(_ entry: GeometryModifierEntry, entityID: UInt64, fallback: T,
                           get: @escaping (GeometryModifier) -> T,
                           set: @escaping (inout GeometryModifier,T) throws -> Void) -> Binding<T> {
        binding(entityID,fallback: fallback,get: { doc in
            doc.modifiers.first { $0.id == entry.id }.map { get($0.operation) } ?? fallback
        },set: { doc,value in
            guard let index = doc.modifiers.firstIndex(where: { $0.id == entry.id }) else { return }
            try set(&doc.modifiers[index].operation,value)
        })
    }

    func modifierFields(_ entry: GeometryModifierEntry, entityID: UInt64) -> [EditorInspectorField] {
        let id = entry.id
        switch entry.operation {
        case let .subdivision(levels):
            return [number("\(id)-levels","Levels",modifierBinding(entry,entityID: entityID,fallback: Float(levels),
                get: { if case let .subdivision(n) = $0 { return Float(n) }; return 0 },
                set: { [self] op,v in op = .subdivision(levels: try integer(v,0...6)) }),min: 0,max: 6,step: 1)]
        case let .solidify(thickness):
            return [number("\(id)-thickness","Thickness",modifierBinding(entry,entityID: entityID,fallback: thickness,
                get: { if case let .solidify(t) = $0 { return t }; return 0.1 },set: { $0 = .solidify(thickness: $1) }),min: 0.0001)]
        case let .array(count,offset):
            return [number("\(id)-count","Count",modifierBinding(entry,entityID: entityID,fallback: Float(count),
                get: { if case let .array(n,_) = $0 { return Float(n) }; return 1 },set: { [self] op,v in
                    if case let .array(_,offset) = op { op = .array(count: try integer(v,1...4096),offset: offset) }
                }),min: 1,max: 4096,step: 1),
                vector("\(id)-offset","Offset",entityID: entityID,fallback: offset,get: { doc in
                    if case let .array(_,v)? = doc.modifiers.first(where: { $0.id == id })?.operation { return v }; return .zero
                },set: { doc,v in
                    guard let i = doc.modifiers.firstIndex(where: { $0.id == id }), case let .array(n,_) = doc.modifiers[i].operation else { return }
                    doc.modifiers[i].operation = .array(count: n,offset: v)
                })]
        case let .mirror(axis,offset,weld):
            return [field("\(id)-axis","Axis",.stringOptions(modifierBinding(entry,entityID: entityID,fallback: axis.rawValue,
                get: { if case let .mirror(a,_,_) = $0 { return a.rawValue }; return "x" },set: { op,v in
                    if case let .mirror(_,o,w) = op, let a = GeometryAxis(rawValue: v) { op = .mirror(axis: a,offset: o,weldDistance: w) }
                }),options: [option("x","X"),option("y","Y"),option("z","Z")])),
                number("\(id)-plane","Plane",modifierBinding(entry,entityID: entityID,fallback: offset,
                    get: { if case let .mirror(_,o,_) = $0 { return o }; return 0 },set: { op,v in
                        if case let .mirror(a,_,w) = op { op = .mirror(axis: a,offset: v,weldDistance: w) }
                    })),
                number("\(id)-weld","Weld",modifierBinding(entry,entityID: entityID,fallback: weld,
                    get: { if case let .mirror(_,_,w) = $0 { return w }; return 0 },set: { op,v in
                        if case let .mirror(a,o,_) = op { op = .mirror(axis: a,offset: o,weldDistance: v) }
                    }),min: 0)]
        }
    }
}
