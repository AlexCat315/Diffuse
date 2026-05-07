import CapabilityRuntime
import IntentRuntime
import Testing

@Suite("LocalIntentClassifier")
struct LocalIntentClassifierTests {

    // MARK: - Fixtures

    private static func cap(_ verbID: String,
                             summary: String,
                             args: [CapabilitySymbolicArgument] = []) -> CapabilitySymbolicView {
        CapabilitySymbolicView(
            verbID: verbID,
            summary: summary,
            scope: .sceneGraph,
            targetKind: "entity",
            arguments: args,
            reversible: true,
            previewSupport: CapabilitySymbolicPreviewSupport(mode: .none),
            confirmationPolicy: CapabilitySymbolicConfirmationPolicy(level: .auto),
            failureModes: []
        )
    }

    private static func arg(_ name: String, hint: String) -> CapabilitySymbolicArgument {
        CapabilitySymbolicArgument(name: name, typeID: "string", required: true,
                                   description: hint, llmHint: hint)
    }

    private static func makeCapabilities() -> [CapabilitySymbolicView] {
        [
            cap("scene.spawn_entity",
                summary: "Spawn or create a new entity in the scene",
                args: [arg("label", hint: "entity name label")]),
            cap("scene.delete_entity",
                summary: "Remove or delete a selected entity from the scene",
                args: [arg("targetObjectIDs", hint: "selected entity ids")]),
            cap("scene.set_transform",
                summary: "Move, translate, rotate or scale the selected entity",
                args: [arg("position", hint: "world position xyz"),
                       arg("rotation", hint: "rotation quaternion")]),
            cap("entity.rename",
                summary: "Rename or relabel an entity",
                args: [arg("newName", hint: "new entity name")]),
            cap("entity.duplicate",
                summary: "Duplicate or copy the selected entity"),
        ]
    }

    // MARK: - English queries

    @Test("English: 'create a new entity' → scene.spawn_entity")
    func englishCreate() {
        let result = classify("create a new entity")
        #expect(result?.intent?.verb == "scene.spawn_entity")
    }

    @Test("English: 'move the selected object' → scene.set_transform")
    func englishMove() {
        let result = classify("move the selected object")
        #expect(result?.intent?.verb == "scene.set_transform")
    }

    @Test("English: 'delete this entity' → scene.delete_entity")
    func englishDelete() {
        let result = classify("delete this entity")
        #expect(result?.intent?.verb == "scene.delete_entity")
    }

    @Test("English: 'rename the object to Hero' → entity.rename")
    func englishRename() {
        let result = classify("rename the object to Hero")
        #expect(result?.intent?.verb == "entity.rename")
    }

    @Test("English: 'duplicate the selection' → entity.duplicate")
    func englishDuplicate() {
        let result = classify("duplicate the selection")
        #expect(result?.intent?.verb == "entity.duplicate")
    }

    // MARK: - Chinese queries

    @Test("Chinese: '创建实体' → scene.spawn_entity")
    func chineseCreate() {
        let result = classify("创建实体")
        #expect(result?.intent?.verb == "scene.spawn_entity")
    }

    @Test("Chinese: '移动选中的对象' → scene.set_transform")
    func chineseMove() {
        let result = classify("移动选中的对象")
        #expect(result?.intent?.verb == "scene.set_transform")
    }

    @Test("Chinese: '删除这个实体' → scene.delete_entity")
    func chineseDelete() {
        let result = classify("删除这个实体")
        #expect(result?.intent?.verb == "scene.delete_entity")
    }

    @Test("Chinese: '重命名物体' → entity.rename")
    func chineseRename() {
        let result = classify("重命名物体")
        #expect(result?.intent?.verb == "entity.rename")
    }

    @Test("Chinese: '复制选中的实体' → entity.duplicate")
    func chineseDuplicate() {
        let result = classify("复制选中的实体")
        #expect(result?.intent?.verb == "entity.duplicate")
    }

    // MARK: - Synonym expansion

    @Test("Synonym: 'spawn a mesh' hits create group → scene.spawn_entity")
    func synonymSpawn() {
        let result = classify("spawn a mesh")
        #expect(result?.intent?.verb == "scene.spawn_entity")
    }

    @Test("Synonym: 'translate position' hits move group → scene.set_transform")
    func synonymTranslate() {
        let result = classify("translate position")
        #expect(result?.intent?.verb == "scene.set_transform")
    }

    @Test("Synonym: 'clone object' hits duplicate group → entity.duplicate")
    func synonymClone() {
        let result = classify("clone object")
        #expect(result?.intent?.verb == "entity.duplicate")
    }

    // MARK: - Confidence threshold

    @Test("Gibberish query returns nil (below threshold)")
    func gibberishReturnsNil() {
        let result = classify("xyzzy frobble quux")
        #expect(result == nil)
    }

    @Test("Empty query returns nil")
    func emptyReturnsNil() {
        let result = classify("")
        #expect(result == nil)
    }

    @Test("High threshold blocks confident match")
    func highThresholdBlocks() {
        let intent = NaturalLanguageIntent(text: "create a new entity", source: .human)
        let context = NaturalLanguageIntentContext()
        let classifier = LocalIntentClassifier(confidenceThreshold: 0.99)
        let result = classifier.classify(intent, context: context,
                                         capabilities: Self.makeCapabilities())
        #expect(result == nil)
    }

    // MARK: - Result structure

    @Test("Result carries correct source, confidence and evidence")
    func resultStructure() throws {
        let result = try #require(classify("create a new entity"))
        let ir = try #require(result.intent)
        #expect(ir.source == .human)
        #expect(ir.confidence > 0)
        #expect(ir.confidence <= 1.0)
        #expect(!ir.evidence.isEmpty)
        #expect(result.candidates.first?.verbID == "scene.spawn_entity")
        #expect(result.candidates.first?.reason == "token_overlap")
    }

    @Test("Context selectedObjectIDs are forwarded to targetObjectIDs")
    func contextObjectIDs() throws {
        let ids = ["42", "99"]
        let intent = NaturalLanguageIntent(text: "move selection", source: .human)
        let context = NaturalLanguageIntentContext(selectedObjectIDs: ids)
        let classifier = LocalIntentClassifier()
        let result = try #require(classifier.classify(intent, context: context,
                                                       capabilities: Self.makeCapabilities()))
        let ir = try #require(result.intent)
        #expect(ir.targetObjectIDs == ids)
    }

    // MARK: - Helper

    private func classify(_ text: String) -> IntentResolutionResult? {
        let intent = NaturalLanguageIntent(text: text, source: .human)
        let context = NaturalLanguageIntentContext()
        let classifier = LocalIntentClassifier()
        return classifier.classify(intent, context: context,
                                   capabilities: Self.makeCapabilities())
    }
}
