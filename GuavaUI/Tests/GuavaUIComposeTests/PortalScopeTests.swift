import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

/// Phase 3 acceptance: overlay state is scoped per window, not process-global
/// (坏味 #3). Two windows' portal stores never see each other's entries, and a
/// `PortalStoreAmbient` attached to a `PlatformInputContext` swaps the active
/// store in lockstep with `withCurrent` (and restores it on exit).
@Suite("Portal scope isolation (Phase 3)", .serialized)
struct PortalScopeTests: GuavaUIComposeSerializedSuite {

    private func entry() -> AnyView { AnyView(EmptyView()) }

    @Test("Distinct PortalStores do not share entries")
    func storesAreIsolated() { GlobalTestLock.locked {
        let saved = PortalStoreHolder.current
        defer { PortalStoreHolder.current = saved }

        let a = PortalStore()
        let b = PortalStore()

        PortalStoreHolder.current = a
        PortalRegistry.register(position: .zero, content: entry())
        #expect(a.entries.count == 1)
        #expect(b.entries.isEmpty)

        PortalStoreHolder.current = b
        #expect(PortalRegistry.entries.isEmpty) // shim reads b now
        PortalRegistry.register(position: .zero, content: entry())
        #expect(b.entries.count == 1)
        #expect(a.entries.count == 1) // a untouched
    } }

    @Test("PortalStoreAmbient swaps the store in lockstep with withCurrent")
    func ambientScopesWithContext() { GlobalTestLock.locked {
        let saved = PortalStoreHolder.current
        defer { PortalStoreHolder.current = saved }

        let storeA = PortalStore()
        let ctxA = PlatformInputContext()
        ctxA.addScopedAmbient(PortalStoreAmbient(storeA))

        let storeB = PortalStore()
        let ctxB = PlatformInputContext()
        ctxB.addScopedAmbient(PortalStoreAmbient(storeB))

        ctxA.withCurrent {
            PortalRegistry.register(position: .zero, content: entry())
        }
        ctxB.withCurrent {
            // B's scope starts empty — A's entry did not leak in.
            #expect(PortalRegistry.entries.isEmpty)
            PortalRegistry.register(position: .zero, content: entry())
        }

        #expect(storeA.entries.count == 1)
        #expect(storeB.entries.count == 1)
    } }

    @Test("Nested scopes restore the outer store on exit")
    func nestedScopesRestore() { GlobalTestLock.locked {
        let saved = PortalStoreHolder.current
        defer { PortalStoreHolder.current = saved }

        let storeA = PortalStore()
        let ctxA = PlatformInputContext()
        ctxA.addScopedAmbient(PortalStoreAmbient(storeA))

        let storeB = PortalStore()
        let ctxB = PlatformInputContext()
        ctxB.addScopedAmbient(PortalStoreAmbient(storeB))

        ctxA.withCurrent {
            #expect(PortalStoreHolder.current === storeA)
            ctxB.withCurrent {
                #expect(PortalStoreHolder.current === storeB)
            }
            // Inner scope exited — A is current again.
            #expect(PortalStoreHolder.current === storeA)
        }
        #expect(PortalStoreHolder.current === saved)
    } }
}
