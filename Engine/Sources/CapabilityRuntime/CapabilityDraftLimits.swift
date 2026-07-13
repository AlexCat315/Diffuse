/// Shared protocol limits used by contract generation without depending on AIRuntime.
public enum CapabilityDraftLimits {
    public static let maximumDraftsPerPlan = 100
    public static let maximumInputBytes = 1_048_576
    public static let timeToLiveSeconds: Double = 5 * 60
}
