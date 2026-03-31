import Foundation
import simd

// MARK: - Bone Hierarchy

enum CatBone: Int, CaseIterable {
    case root = 0
    case body
    case head
    case leftEar, rightEar
    case frontLeftUpperLeg, frontLeftLowerLeg
    case frontRightUpperLeg, frontRightLowerLeg
    case rearLeftUpperLeg, rearLeftLowerLeg
    case rearRightUpperLeg, rearRightLowerLeg
    case tail1, tail2, tail3
}

struct VoxelVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

struct CatPose {
    var boneAngles: [SIMD3<Float>]  // indexed by CatBone.rawValue, euler XYZ radians

    static let rest: CatPose = {
        var angles = [SIMD3<Float>](repeating: .zero, count: CatBone.allCases.count)
        return CatPose(boneAngles: angles)
    }()

    mutating func set(_ bone: CatBone, _ angles: SIMD3<Float>) {
        boneAngles[bone.rawValue] = angles
    }

    func get(_ bone: CatBone) -> SIMD3<Float> {
        boneAngles[bone.rawValue]
    }
}

// MARK: - Bone Definition

struct BoneDef {
    let parent: CatBone?
    let jointOffset: SIMD3<Float>   // offset from parent's joint to this joint
    let boxSize: SIMD3<Float>       // visual box dimensions
    let boxCenter: SIMD3<Float>     // box center relative to this joint
    let color: SIMD4<Float>
}

// MARK: - Voxel Cat Model

final class VoxelCatModel {
    // Minecraft-ish proportions. Units are "voxels" (~4-5px each at default scale).
    // Cat walks along +Z, Y is up, X is right.
    // Body center at origin, legs hang down, head extends forward.

    static let furOrange   = SIMD4<Float>(0.89, 0.55, 0.22, 1)
    static let furDark     = SIMD4<Float>(0.68, 0.38, 0.14, 1)
    static let furLight    = SIMD4<Float>(0.96, 0.78, 0.52, 1)
    static let belly       = SIMD4<Float>(0.95, 0.88, 0.76, 1)
    static let earPink     = SIMD4<Float>(0.90, 0.58, 0.52, 1)
    static let nose        = SIMD4<Float>(0.88, 0.42, 0.38, 1)
    static let eyeGreen    = SIMD4<Float>(0.30, 0.72, 0.38, 1)
    static let outline     = SIMD4<Float>(0.14, 0.11, 0.09, 1)
    static let pawPad      = SIMD4<Float>(0.82, 0.48, 0.42, 1)
    static let tailTip     = SIMD4<Float>(0.52, 0.30, 0.12, 1)

    static let bones: [CatBone: BoneDef] = {
        var b = [CatBone: BoneDef]()

        // Root: virtual, at ground level under body center
        b[.root] = BoneDef(parent: nil,
            jointOffset: .zero,
            boxSize: .zero, boxCenter: .zero, color: .zero)

        // Body: center at y=3.5 (half body height above root joint which is at y=0 ground + leg height)
        b[.body] = BoneDef(parent: .root,
            jointOffset: SIMD3(0, 5, 0),  // body joint at leg-top height
            boxSize: SIMD3(5, 4, 9),
            boxCenter: SIMD3(0, 0, 0),
            color: furOrange)

        // Head: attached at front-top of body
        b[.head] = BoneDef(parent: .body,
            jointOffset: SIMD3(0, 1.5, 5),
            boxSize: SIMD3(4.5, 4, 4.5),
            boxCenter: SIMD3(0, 1.5, 1.5),
            color: furOrange)

        // Ears
        b[.leftEar] = BoneDef(parent: .head,
            jointOffset: SIMD3(-1.2, 3.5, 1.5),
            boxSize: SIMD3(1.2, 1.8, 0.8),
            boxCenter: SIMD3(0, 0.9, 0),
            color: earPink)

        b[.rightEar] = BoneDef(parent: .head,
            jointOffset: SIMD3(1.2, 3.5, 1.5),
            boxSize: SIMD3(1.2, 1.8, 0.8),
            boxCenter: SIMD3(0, 0.9, 0),
            color: earPink)

        // Front legs - joints at front corners of body
        b[.frontLeftUpperLeg] = BoneDef(parent: .body,
            jointOffset: SIMD3(-1.8, -2, 3.5),
            boxSize: SIMD3(1.6, 3.0, 1.6),
            boxCenter: SIMD3(0, -1.5, 0),
            color: furOrange)

        b[.frontLeftLowerLeg] = BoneDef(parent: .frontLeftUpperLeg,
            jointOffset: SIMD3(0, -3.0, 0),
            boxSize: SIMD3(1.4, 2.5, 1.6),
            boxCenter: SIMD3(0, -1.25, 0),
            color: furLight)

        b[.frontRightUpperLeg] = BoneDef(parent: .body,
            jointOffset: SIMD3(1.8, -2, 3.5),
            boxSize: SIMD3(1.6, 3.0, 1.6),
            boxCenter: SIMD3(0, -1.5, 0),
            color: furOrange)

        b[.frontRightLowerLeg] = BoneDef(parent: .frontRightUpperLeg,
            jointOffset: SIMD3(0, -3.0, 0),
            boxSize: SIMD3(1.4, 2.5, 1.6),
            boxCenter: SIMD3(0, -1.25, 0),
            color: furLight)

        // Rear legs
        b[.rearLeftUpperLeg] = BoneDef(parent: .body,
            jointOffset: SIMD3(-1.8, -2, -3.5),
            boxSize: SIMD3(1.6, 3.0, 1.6),
            boxCenter: SIMD3(0, -1.5, 0),
            color: furOrange)

        b[.rearLeftLowerLeg] = BoneDef(parent: .rearLeftUpperLeg,
            jointOffset: SIMD3(0, -3.0, 0),
            boxSize: SIMD3(1.4, 2.5, 1.6),
            boxCenter: SIMD3(0, -1.25, 0),
            color: furLight)

        b[.rearRightUpperLeg] = BoneDef(parent: .body,
            jointOffset: SIMD3(1.8, -2, -3.5),
            boxSize: SIMD3(1.6, 3.0, 1.6),
            boxCenter: SIMD3(0, -1.5, 0),
            color: furOrange)

        b[.rearRightLowerLeg] = BoneDef(parent: .rearRightUpperLeg,
            jointOffset: SIMD3(0, -3.0, 0),
            boxSize: SIMD3(1.4, 2.5, 1.6),
            boxCenter: SIMD3(0, -1.25, 0),
            color: furLight)

        // Tail segments
        b[.tail1] = BoneDef(parent: .body,
            jointOffset: SIMD3(0, 1, -4.5),
            boxSize: SIMD3(0.9, 0.9, 3.2),
            boxCenter: SIMD3(0, 0, -1.6),
            color: furOrange)

        b[.tail2] = BoneDef(parent: .tail1,
            jointOffset: SIMD3(0, 0, -3.2),
            boxSize: SIMD3(0.8, 0.8, 3.0),
            boxCenter: SIMD3(0, 0, -1.5),
            color: furDark)

        b[.tail3] = BoneDef(parent: .tail2,
            jointOffset: SIMD3(0, 0, -3.0),
            boxSize: SIMD3(0.7, 0.7, 2.5),
            boxCenter: SIMD3(0, 0, -1.25),
            color: tailTip)

        return b
    }()

    // Rendering order: back-to-front for correct painter's algorithm feel
    // (though we use depth buffer, order still helps with equal-depth)
    static let renderOrder: [CatBone] = [
        .tail3, .tail2, .tail1,
        .rearLeftLowerLeg, .rearLeftUpperLeg,
        .rearRightLowerLeg, .rearRightUpperLeg,
        .body,
        .frontLeftLowerLeg, .frontLeftUpperLeg,
        .frontRightLowerLeg, .frontRightUpperLeg,
        .head,
        .leftEar, .rightEar,
    ]

    // MARK: - Geometry Generation

    /// Generate all vertices for the cat in world space given a pose and root transform.
    /// rootPosition is the cat's XZ position on the stage (in stage pixels).
    /// heading is the cat's facing angle (radians, 0 = facing +Z / down on screen).
    /// scale converts voxel units to stage pixels.
    static func generateVertices(
        pose: CatPose,
        rootPosition: SIMD2<Float>,
        heading: Float,
        scale: Float
    ) -> [VoxelVertex] {
        // Compute world transforms for each bone
        var worldTransforms = [CatBone: matrix_float4x4]()

        for bone in CatBone.allCases {
            guard let def = bones[bone] else { continue }

            let localRotation = pose.get(bone)
            let rotMatrix = makeRotation(euler: localRotation)
            let transMatrix = makeTranslation(def.jointOffset * scale)
            let localTransform = transMatrix * rotMatrix

            if bone == .root {
                // Root: position on stage + heading
                let rootTrans = makeTranslation(SIMD3(rootPosition.x, 0, rootPosition.y))
                let rootRot = makeRotationY(heading)
                worldTransforms[bone] = rootTrans * rootRot * localTransform
            } else if let parent = def.parent, let parentWorld = worldTransforms[parent] {
                worldTransforms[bone] = parentWorld * localTransform
            }
        }

        // Generate box vertices for each bone
        var vertices: [VoxelVertex] = []
        vertices.reserveCapacity(renderOrder.count * 36)

        for bone in renderOrder {
            guard let def = bones[bone], def.boxSize.x > 0,
                  let worldTransform = worldTransforms[bone] else { continue }

            let boxVerts = makeBox(
                center: def.boxCenter * scale,
                halfSize: def.boxSize * 0.5 * scale,
                color: def.color,
                transform: worldTransform
            )
            vertices.append(contentsOf: boxVerts)
        }

        return vertices
    }

    // MARK: - Box Geometry

    private static func makeBox(
        center: SIMD3<Float>,
        halfSize: SIMD3<Float>,
        color: SIMD4<Float>,
        transform: matrix_float4x4
    ) -> [VoxelVertex] {
        let hx = halfSize.x, hy = halfSize.y, hz = halfSize.z
        let cx = center.x, cy = center.y, cz = center.z

        // 8 corners
        let corners: [SIMD3<Float>] = [
            SIMD3(cx - hx, cy - hy, cz - hz), // 0: left-bottom-back
            SIMD3(cx + hx, cy - hy, cz - hz), // 1: right-bottom-back
            SIMD3(cx + hx, cy + hy, cz - hz), // 2: right-top-back
            SIMD3(cx - hx, cy + hy, cz - hz), // 3: left-top-back
            SIMD3(cx - hx, cy - hy, cz + hz), // 4: left-bottom-front
            SIMD3(cx + hx, cy - hy, cz + hz), // 5: right-bottom-front
            SIMD3(cx + hx, cy + hy, cz + hz), // 6: right-top-front
            SIMD3(cx - hx, cy + hy, cz + hz), // 7: left-top-front
        ]

        // 6 faces, 2 triangles each = 36 vertices
        // Each face: normal, 4 corner indices (as 2 triangles)
        let faces: [(normal: SIMD3<Float>, indices: [Int])] = [
            (SIMD3( 0,  0, -1), [0, 2, 1, 0, 3, 2]), // back
            (SIMD3( 0,  0,  1), [4, 5, 6, 4, 6, 7]), // front
            (SIMD3(-1,  0,  0), [0, 4, 7, 0, 7, 3]), // left
            (SIMD3( 1,  0,  0), [1, 2, 6, 1, 6, 5]), // right
            (SIMD3( 0,  1,  0), [3, 7, 6, 3, 6, 2]), // top
            (SIMD3( 0, -1,  0), [0, 1, 5, 0, 5, 4]), // bottom
        ]

        // Shade each face differently for that Minecraft look
        let faceTints: [Float] = [0.70, 0.85, 0.75, 0.80, 1.0, 0.60]

        var verts: [VoxelVertex] = []
        verts.reserveCapacity(36)

        for (fi, face) in faces.enumerated() {
            let worldNormal = (transform * SIMD4(face.normal, 0)).xyz
            let tint = faceTints[fi]
            let facedColor = SIMD4<Float>(color.x * tint, color.y * tint, color.z * tint, color.w)

            for idx in face.indices {
                let worldPos = (transform * SIMD4(corners[idx], 1)).xyz
                verts.append(VoxelVertex(
                    position: worldPos,
                    normal: worldNormal,
                    color: facedColor
                ))
            }
        }

        return verts
    }

    // MARK: - Matrix Helpers

    static func makeTranslation(_ t: SIMD3<Float>) -> matrix_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func makeRotationX(_ angle: Float) -> matrix_float4x4 {
        let c = cos(angle), s = sin(angle)
        return matrix_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func makeRotationY(_ angle: Float) -> matrix_float4x4 {
        let c = cos(angle), s = sin(angle)
        return matrix_float4x4(columns: (
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func makeRotationZ(_ angle: Float) -> matrix_float4x4 {
        let c = cos(angle), s = sin(angle)
        return matrix_float4x4(columns: (
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func makeRotation(euler: SIMD3<Float>) -> matrix_float4x4 {
        makeRotationZ(euler.z) * makeRotationY(euler.y) * makeRotationX(euler.x)
    }
}

// MARK: - SIMD4 xyz helper

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
