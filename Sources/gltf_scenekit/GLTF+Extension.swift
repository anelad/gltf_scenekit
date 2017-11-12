//
//  GLTF+Extension.swift
//  
//
//  Created by Volodymyr Boichentsov on 13/10/2017.
//  Copyright © 2017 Volodymyr Boichentsov. All rights reserved.
//

import Foundation
import SceneKit

extension GLTF {

    private static var associationMap = [String: Any]()
    private struct Keys {
        static var cache_nodes:String = "cache_nodes"
        static var animation_duration:String = "animation_duration"
        static var _directory:String = "directory"
        static var _cameraCreated:String = "_cameraCreated"
    }
    
    private var cache_nodes:[SCNNode?]? {
        get { return GLTF.associationMap[Keys.cache_nodes] as? [SCNNode?] }
        set { if newValue != nil { GLTF.associationMap[Keys.cache_nodes] = newValue } }
    }
    
    private var animationDuration:Double {
        get { return (GLTF.associationMap[Keys.animation_duration] as? Double) ?? 0 }
        set { GLTF.associationMap[Keys.animation_duration] = newValue }
    }
    
    public var directory:String? {
        get { return GLTF.associationMap[Keys._directory] as? String }
        set { GLTF.associationMap[Keys._directory] = newValue }
    }

    private var cameraCreated:Bool {
        get { return (GLTF.associationMap[Keys._cameraCreated] as? Bool) ?? false }
        set { GLTF.associationMap[Keys._cameraCreated] = newValue }
    }
    
    /// Convert GLTF to SceneKit scene. 
    ///
    /// - Parameter directory: location of other related resources to gltf
    /// - Returns: instance of Scene
    open func convertToSCNScene(directory:String) -> SCNScene {
        self.directory = directory
        let scene:SCNScene = SCNScene.init()
        if self.scenes != nil && self.scene != nil {
            let sceneGlTF = self.scenes![(self.scene)!]
            if let sceneName = sceneGlTF.name {
                scene.setAttribute(sceneName, forKey: "name")
            }

            self.cache_nodes = [SCNNode?](repeating: nil, count: (self.nodes?.count)!)
            
            // parse modes
            for nodeIndex in sceneGlTF.nodes! {
                let node = buildNode(index:nodeIndex)
                scene.rootNode.addChildNode(node)
                
                node.runAction(SCNAction.rotateBy(x: 0, y: .pi, z: 0, duration: 0))
            }
            
            parseAnimations()
            
            cleanExtras()
            
            GLTF.associationMap = [String: Any]()
        }
        
        return scene
    }
    
    fileprivate func parseAnimations() {
        if self.animations != nil {
            for animation in self.animations! {
                for channel in animation.channels! {
                    if channel.sampler != nil && channel.target != nil {
                        let sampler = animation.samplers![channel.sampler!]
                        do {
                            try constructAnimation(sampler: sampler, target:channel.target!)
                        } catch {
                            print(error)
                        }
                    }
                }
            }
        }
        
        for node in self.cache_nodes! {
            let group = node?.value(forUndefinedKey: "group") as? CAAnimationGroup
            if group != nil && self.animationDuration != 0 {
                group?.duration = self.animationDuration
            }
        }
    }
    
    fileprivate func constructAnimation(sampler:GLTFAnimationSampler, target:GLTFAnimationChannelTarget ) throws {
        
        let node:SCNNode = self.cache_nodes![target.node!]!
        
        let accessorInput = self.accessors![sampler.input!]
        let accessorOutput = self.accessors![sampler.output!]
        
        let keyTimesFloat = loadAccessorAsArray(accessorInput) as! [Float]
        let duration = Double(keyTimesFloat.last!)
        let f_duration = Float(duration)
        let keyTimes: [NSNumber] = keyTimesFloat.map { NSNumber(value: $0 / f_duration ) }
        
        let values_ = loadAccessorAsArray(accessorOutput)
        
        var groupDuration:Double = 0
        
        var caanimations:[CAAnimation] = [CAAnimation]() 
        if target.path! == .weights {
            let weightPaths = node.value(forUndefinedKey: "weightPaths") as? [String]
                        
            groupDuration = duration
            
            var keyAnimations = [CAKeyframeAnimation]()
            for path in weightPaths! {
                let animation = CAKeyframeAnimation()
                animation.keyPath = path
                animation.keyTimes = keyTimes
                animation.duration = duration
                keyAnimations.append(animation)
            }
                        
            let step = keyAnimations.count
            let dataLength = values_.count / step
            guard dataLength == keyTimes.count else {
                throw "data count mismatch: \(dataLength) != \(keyTimes.count)"
            }
            
            for i in 0..<keyAnimations.count {
                var valueIndex = i
                var v = [NSNumber]()
                v.reserveCapacity(dataLength)
                for _ in 0..<dataLength {
                    v.append(NSNumber(value: (values_[valueIndex] as! Float) ))
                    valueIndex += step
                }
                keyAnimations[i].values = v
            }
            
            caanimations = keyAnimations
            
        } else {
            let keyFrameAnimation = CAKeyframeAnimation()
            
            self.animationDuration = max(self.animationDuration, duration)
            
            keyFrameAnimation.keyPath = target.path?.scn()
            keyFrameAnimation.keyTimes = keyTimes
            keyFrameAnimation.values = values_
            keyFrameAnimation.repeatCount = .infinity
            keyFrameAnimation.duration = duration
            
            caanimations.append(keyFrameAnimation)
            
            groupDuration = self.animationDuration
        }
        
        let group = (node.value(forUndefinedKey: "group") as? CAAnimationGroup) ?? CAAnimationGroup()
        node.setValue(group, forUndefinedKey: "group")
        var animations = group.animations ?? []
        animations.append(contentsOf: caanimations)
        group.animations = animations 
        group.duration = groupDuration
        group.repeatCount = .infinity
        node.addAnimation(group, forKey: target.path?.rawValue)
    }
    
    // MARK: - Nodes
    
    fileprivate func buildNode(index:Int) -> SCNNode {
        let scnNode = SCNNode()
        if self.nodes != nil {
            let node = self.nodes![index]
            scnNode.name = node.name
            
            // Get camera.
            constructCamera(node, scnNode)
            
            // Mesh
            geometryNode(node, scnNode)
            
            var weightPaths = [String]()
            for i in 0..<scnNode.childNodes.count {
                let primitive = scnNode.childNodes[i]
                if let morpher = primitive.morpher {
                    for j in 0..<morpher.targets.count {
                        let path = "childNodes[\(i)].morpher.weights[\(j)]"
                        weightPaths.append(path)
                    }
                }
            }
            scnNode.setValue(weightPaths, forUndefinedKey: "weightPaths")
            
            // load skin
            if let skin = node.skin {
                loadSkin(skin, scnNode)
            }
            
            // bake all transformations into one mtarix
            scnNode.transform = bakeTransformationMatrix(node)
            
            self.cache_nodes?[index] = scnNode
            
            if let children = node.children {
                for i in children {
                    let subSCNNode = buildNode(index:i)
                    scnNode.addChildNode(subSCNNode)
                }
            }
        }
        return scnNode
    }
    
    fileprivate func bakeTransformationMatrix(_ node:GLTFNode) -> SCNMatrix4 {
        let rotation = GLKMatrix4MakeWithQuaternion(GLKQuaternion.init(q: (Float(node.rotation[0]), Float(node.rotation[1]), Float(node.rotation[2]), Float(node.rotation[3]))))
        var matrix = SCNMatrix4.init(array:node.matrix)
        matrix = SCNMatrix4Translate(matrix, SCNFloat(node.translation[0]), SCNFloat(node.translation[1]), SCNFloat(node.translation[2]))
        matrix = SCNMatrix4Mult(matrix, SCNMatrix4FromGLKMatrix4(rotation)) 
        matrix = SCNMatrix4Scale(matrix, SCNFloat(node.scale[0]), SCNFloat(node.scale[1]), SCNFloat(node.scale[2]))
        return matrix
    }
    
    fileprivate func constructCamera(_ node:GLTFNode, _ scnNode:SCNNode) {
        if let cameraIndex = node.camera {
            scnNode.camera = SCNCamera()
            if self.cameras != nil {
                let camera = self.cameras![cameraIndex]
                scnNode.camera?.name = camera.name
                switch camera.type {
                case .perspective?:
                    scnNode.camera?.zNear = (camera.perspective?.znear)!
                    scnNode.camera?.zFar = (camera.perspective?.zfar)!
                    if #available(OSX 10.13, *) {
                        scnNode.camera?.fieldOfView = CGFloat((camera.perspective?.yfov)! * 180.0 / .pi)
                        scnNode.camera?.wantsDepthOfField = true
                        scnNode.camera?.motionBlurIntensity = 0.3
                    }
                    break
                case .orthographic?:
                    scnNode.camera?.usesOrthographicProjection = true
                    scnNode.camera?.zNear = (camera.orthographic?.znear)!
                    scnNode.camera?.zFar = (camera.orthographic?.zfar)!
                    break
                case .none:
                    break
                }
            }
        }
    }  
    
    // convert glTF mesh into SCNGeometry
    fileprivate func geometryNode(_ node:GLTFNode, _ scnNode:SCNNode) {
        if let meshIndex = node.mesh {
            if self.meshes != nil {
                let mesh = self.meshes![meshIndex]
                scnNode.name = mesh.name
                for primitive in mesh.primitives! {
                    // get indices data
                    let element = self.geometryElement(primitive)
                    
                    // get vertices data
                    let sources = self.loadSources(primitive.attributes!)
                    
                    let geometry = SCNGeometry.init(sources: sources, elements: [element])
                    
                    if let materialIndex = primitive.material {
                        let scnMaterial = self.material(index:materialIndex)
                        geometry.materials = [scnMaterial]
                    }
                    
                    let primitiveNode = SCNNode.init(geometry: geometry)
                    
                    if let targets = primitive.targets {
                        let morpher = SCNMorpher()
                        for targetIndex in 0..<targets.count {
                            let target = targets[targetIndex]
                            let sourcesMorph = loadSources(target)
                            let geometryMorph = SCNGeometry(sources: sourcesMorph, elements: nil)
                            morpher.targets.append(geometryMorph)
                        }
                        morpher.calculationMode = .additive
                        primitiveNode.morpher = morpher
                    }
                    
                    scnNode.addChildNode(primitiveNode)
                }
            }
        }
    }
    
    fileprivate func geometryElement(_ primitive: GLTFMeshPrimitive) -> SCNGeometryElement {
        if let indicesIndex = primitive.indices {
            if self.accessors != nil && self.bufferViews != nil {
                let accessor = self.accessors![indicesIndex]
 
                let indicesData = loadData(accessor)
                    
                var count = (accessor.count == nil) ? 0 : accessor.count!
                
                let primitiveType = primitive.mode.scn()
                switch primitiveType {
                case .triangles:
                    count = count/3
                    break
                case .triangleStrip:
                    count = count-2
                    break
                case .line:
                    count = count/2
                default:
                    break
                }
                
                return SCNGeometryElement.init(data: indicesData,
                                               primitiveType: primitiveType,
                                               primitiveCount: count,
                                               bytesPerIndex: accessor.bytesPerElement())
            }
        }
        return SCNGeometryElement.init()
    }

    fileprivate func loadSources(_ attributes:[String:Int]) -> [SCNGeometrySource]  {
        var geometrySources = [SCNGeometrySource]()
        for (key, accessorIndex) in attributes {
            if self.accessors != nil && self.bufferViews != nil {
                let accessor = self.accessors![accessorIndex]
                if let data = loadData(accessor) {
                    
                    let count = (accessor.count == nil) ? 0 : accessor.count!
                    let byteStride = accessor.components()*accessor.bytesPerElement()  
                    
                    let semantic = sourceSemantic(name:key)
                    
                    let geometrySource = SCNGeometrySource.init(data: data, 
                                                                semantic: semantic, 
                                                                vectorCount: count, 
                                                                usesFloatComponents: true, 
                                                                componentsPerVector: accessor.components(), 
                                                                bytesPerComponent: accessor.bytesPerElement(), 
                                                                dataOffset: 0, 
                                                                dataStride: byteStride)
                    geometrySources.append(geometrySource)
                }
            }
        }
        return geometrySources
    }
    
    // get data by accessor
    fileprivate func loadData(_ accessor:GLTFAccessor) -> Data? {
        let bufferView = self.bufferViews![accessor.bufferView!] 
        if self.buffers != nil && bufferView.buffer! < self.buffers!.count { 
            let buffer = self.buffers![bufferView.buffer!]
            
            let count = (accessor.count == nil) ? 0 : accessor.count!
            let byteStride = (bufferView.byteStride == nil) ? accessor.components()*accessor.bytesPerElement() : bufferView.byteStride!
            let bytesLength = byteStride*count            
            let start = bufferView.byteOffset+accessor.byteOffset
            let end = start+bytesLength
            return buffer.data(inDirectory:self.directory)?.subdata(in: start..<end)
        }
        return nil
    }
    
    fileprivate func loadAccessorAsArray(_ accessor:GLTFAccessor) -> [Any] {
        var values = [Any]()
        if let data = loadData(accessor) {
            switch accessor.componentType! {
            case .BYTE:
                values = data.int8Array
                break
            case .UNSIGNED_BYTE:
                values = data.uint8Array
                break
            case .SHORT:
                values = data.int16Array
                break
            case .UNSIGNED_SHORT:
                values = data.uint16Array
                break
            case .INT:
                values = data.int32Array
                break
            case .UNSIGNED_INT:
                values = data.uint32Array
                break
            case .FLOAT: 
                do {
                    switch accessor.type! {
                    case .SCALAR:
                        values = data.floatArray
                        break
                    case .VEC2:
                        values = data.vec2Array 
                        break
                    case .VEC3:
                        values = data.vec3Array
                        for i in 0..<values.count {
                            values[i] = SCNVector3FromGLKVector3(values[i] as! GLKVector3)
                        }
                        break
                    case .VEC4:
                        values = data.vec4Array
                        for i in 0..<values.count {
                            values[i] = SCNVector4FromGLKVector4(values[i] as! GLKVector4)
                        }
                        break
                    case .MAT2:
                        break
                    case .MAT3:
                        break
                    case .MAT4:
                        values = data.mat4Array
                        for i in 0..<values.count {
                            values[i] = SCNMatrix4FromGLKMatrix4(values[i] as! GLKMatrix4)
                        }
                        break
                    }
                }
                break
            }
        } 
        return values
    }
    
    // convert attributes name to SceneKit semantic
    fileprivate func sourceSemantic(name:String) -> SCNGeometrySource.Semantic {
        switch name {
        case "POSITION":
            return .vertex
        case "NORMAL":
            return .normal
        case "TANGENT":
            return .tangent
        case "COLOR":
            return .color
        case "TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2", "TEXCOORD_3", "TEXCOORD_4":
            return .texcoord
        case "JOINTS_0":
            return .boneIndices
        case "WEIGHTS_0":
            return .boneWeights
        default:
            return .vertex
        }
    }
    
    fileprivate func loadSkin(_ skin:Int, _ scnNode:SCNNode) {
        // TODO: implement
    }
    
    
    // MARK: - Material
    
    // load material by index
    fileprivate func material(index:Int) -> SCNMaterial {
        let scnMaterial = SCNMaterial()
        if self.materials != nil && index < (self.materials?.count)! {
            let material = self.materials![index]
            scnMaterial.name = material.name
            scnMaterial.isDoubleSided = material.doubleSided
            
            if let pbr = material.pbrMetallicRoughness {
                scnMaterial.lightingModel = .physicallyBased
                if let baseTextureInfo = pbr.baseColorTexture {
                    self.loadTexture(index:baseTextureInfo.index!, property: scnMaterial.diffuse)
                } else {
                    let color = (pbr.baseColorFactor.count < 4) ? [1, 1, 1, 1] : (pbr.baseColorFactor)
                    scnMaterial.diffuse.contents = ColorClass(red: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: CGFloat(color[3]))
                }
                
                if let metallicRoughnessTextureInfo = pbr.metallicRoughnessTexture {
                    if #available(OSX 10.13, *) {
                        scnMaterial.metalness.textureComponents = .blue
                        scnMaterial.roughness.textureComponents = .green
                        self.loadTexture(index:metallicRoughnessTextureInfo.index!, property: scnMaterial.metalness)
                        self.loadTexture(index:metallicRoughnessTextureInfo.index!, property: scnMaterial.roughness)
                    } else {
                        // Fallback on earlier versions
                        if self.textures != nil &&  metallicRoughnessTextureInfo.index! < (self.textures?.count)! {
                            let texture = self.textures![metallicRoughnessTextureInfo.index!]
                            if texture.source != nil {
                                
                                loadSampler(sampler:texture.sampler, property: scnMaterial.roughness)
                                loadSampler(sampler:texture.sampler, property: scnMaterial.metalness)
                                
                                let image = self.image(byIndex:texture.source!)
                                if let images = try? image?.channels() {
                                    scnMaterial.roughness.contents = images?[1]
                                    scnMaterial.metalness.contents = images?[2]
                                }
                            }
                        }
                    }
                    
                } else {
                    scnMaterial.metalness.intensity = CGFloat(pbr.metallicFactor)
                    scnMaterial.roughness.intensity = CGFloat(pbr.roughnessFactor)
                }
            }

            if let normalTextureInfo = material.normalTexture {
                self.loadTexture(index: normalTextureInfo.index!, property: scnMaterial.normal)
            }

            if let occlusionTextureInfo = material.occlusionTexture {
                self.loadTexture(index: occlusionTextureInfo.index!, property: scnMaterial.ambientOcclusion)
                scnMaterial.ambientOcclusion.intensity = CGFloat(occlusionTextureInfo.strength)
            }
            
            if let emissiveTextureInfo = material.emissiveTexture {
                self.loadTexture(index: emissiveTextureInfo.index!, property: scnMaterial.emission)
            } else {
                let color = (material.emissiveFactor.count < 3) ? [1, 1, 1] : (material.emissiveFactor)
                scnMaterial.emission.contents = SCNVector4Make(SCNFloat(color[0]), SCNFloat(color[1]), SCNFloat(color[2]), 1.0)
            }
        }
        
        return scnMaterial
    }
    
    // get image by index
    fileprivate func image(byIndex index:Int) -> ImageClass? {
        if self.images != nil {
            let image = self.images![index]
            return image.image(inDirectory:self.directory)
        }
        return nil
    }
    
    fileprivate func loadTexture(index:Int, property:SCNMaterialProperty) {
        if self.textures != nil && index < self.textures!.count {
            let texture = self.textures![index]
            if texture.source != nil {
                property.contents = self.image(byIndex:texture.source!)
            }
            loadSampler(sampler:texture.sampler, property: property)
        }
    }
    
    fileprivate func loadSampler(sampler samplerIndex:Int?, property:SCNMaterialProperty) {
        if samplerIndex != nil && self.samplers != nil && samplerIndex! < self.samplers!.count {
            let sampler = self.samplers![samplerIndex!]
            property.wrapS = sampler.wrapS.scn()
            property.wrapT = sampler.wrapT.scn()
            property.magnificationFilter = sampler.magFilterScene()
            (property.minificationFilter, property.mipFilter)  = sampler.minFilterScene()
        }
    }
    
    
    fileprivate func cleanExtras() {
        if self.buffers != nil {
            for buffer in self.buffers! {
                buffer.extras = nil
            }
        }
        
        if self.images != nil {
            for image in self.images! {
                image.extras = nil
            }
        }
        
        self.cache_nodes?.removeAll()
    }
}

extension GLTFSampler {
    fileprivate func magFilterScene() -> SCNFilterMode {
        if self.magFilter != nil {
            return (self.magFilter?.scn())!
        }
        return .none
    }
    
    fileprivate func minFilterScene() -> (SCNFilterMode, SCNFilterMode) {
        if self.minFilter != nil {
            return (self.minFilter?.scn())!
        }
        return (.none, .none)
    }
}

extension GLTFSamplerMagFilter {
    fileprivate func scn() -> SCNFilterMode {
        switch self {
        case .LINEAR:
            return .linear
        case .NEAREST:
            return .nearest
        }
    }
}

extension GLTFSamplerMinFilter {
    fileprivate func scn() -> (SCNFilterMode, SCNFilterMode) {
        switch self {
        case .LINEAR:
            return (.linear, .none)
        case .NEAREST:
            return (.nearest, .none)
        case .LINEAR_MIPMAP_LINEAR:
            return (.linear, .linear)
        case .NEAREST_MIPMAP_NEAREST:
            return (.nearest, .nearest)
        case .LINEAR_MIPMAP_NEAREST:
            return (.linear, .nearest)
        case .NEAREST_MIPMAP_LINEAR:
            return (.nearest, .linear)
        }
    }
}

extension GLTFSamplerWrapS {
    fileprivate func scn() -> SCNWrapMode {
        switch self {
        case .CLAMP_TO_EDGE:
            return .clampToBorder
        case .REPEAT:
            return .repeat
        case .MIRRORED_REPEAT:
            return .mirror
        }
    }
}

extension GLTFSamplerWrapT {
    fileprivate func scn() -> SCNWrapMode {
        switch self {
        case .CLAMP_TO_EDGE:
            return .clampToBorder
        case .REPEAT:
            return .repeat
        case .MIRRORED_REPEAT:
            return .mirror
        }
    }
}

extension GLTFBuffer {
    
    fileprivate func data(inDirectory directory:String?) -> Data? {
        var data:Data?
        if self.extras != nil {
            data = self.extras!["data"] as? Data
        }
        if data == nil {
            data = loadURI(uri: self.uri!, inDirectory: directory)
            self.extras = ["data": data as Any as! Decodable & Encodable]
        }
        return data
    } 
}

extension GLTFImage {
    fileprivate func image(inDirectory directory:String?) -> ImageClass? {
        var image:ImageClass?
        if self.extras != nil {
            image = self.extras!["image"] as? ImageClass
        }
        if image == nil {
            if let imageData = loadURI(uri: self.uri!, inDirectory: directory) {
                image = ImageClass.init(data: imageData)
            }
            self.extras = ["image": image as Any as! Decodable & Encodable]
        }
        return image
    } 
}

extension GLTFAccessor {
    fileprivate func components() -> Int {
        if let _type = self.type {
            switch _type {
            case .SCALAR:
                return 1
            case .VEC2:
                return 2
            case .VEC3:
                return 3
            case .VEC4, .MAT2:
                return 4
            case .MAT3:
                return 9
            case .MAT4:
                return 16
            }
        }
        return 0
    }
    
    fileprivate func bytesPerElement() -> Int {
        if let _componentType = self.componentType {
            switch _componentType {
            case .UNSIGNED_BYTE, .BYTE:
                return 1
            case .UNSIGNED_SHORT, .SHORT:
                return 2
            default:
                return 4
            }
        }
        return 0
    }
}

extension GLTFMeshPrimitiveMode {
    fileprivate func scn() -> SCNGeometryPrimitiveType {
        switch self {
        case .POINTS:
            return .point
        case .LINES, .LINE_LOOP, .LINE_STRIP:
            return .line
        case .TRIANGLE_STRIP:
            return .triangleStrip
        case .TRIANGLES:
            return .triangles
        default:
            return .triangles
        }
    }
}

extension GLTFAnimationChannelTargetPath {
    fileprivate func scn() -> String {
        switch self {
        case .translation:
            return "position"
        case .rotation:
            return "orientation"
        case .scale:
            return self.rawValue
        case .weights:
            return self.rawValue
        }
    }
}
