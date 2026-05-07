import Foundation
import Combine
import StoreKit

@MainActor
public final class PurchaseManager: ObservableObject {
    public enum PurchaseState {
        case idle
        case loading
        case failed(String)
    }

    @Published public private(set) var products: [Product] = []
    @Published public private(set) var state: PurchaseState = .idle
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var isLoadingProducts = false

    // Replace with your real product ID in App Store Connect.
    public let productIDs = ["com.barnabywood.saunalog.unlock"]

    private let trialManager: TrialManager
    private var updatesTask: Task<Void, Never>?

    public init(trialManager: TrialManager) {
        self.trialManager = trialManager
    }

    deinit {
        updatesTask?.cancel()
    }

    public func startObservingTransactions() {
        guard updatesTask == nil else { return }

        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                do {
                    let transaction = try self.verify(result)
                    await transaction.finish()
                    self.trialManager.unlock()
                    self.lastErrorMessage = nil
                    self.state = .idle
                } catch {
                    self.setFailure(error.localizedDescription)
                }
            }
        }

        Task {
            await refreshEntitlements()
        }
    }

    public func refreshEntitlements() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            do {
                let _ = try verify(result)
                found = true
                break
            } catch {
                continue
            }
        }

        if found {
            trialManager.unlock()
            lastErrorMessage = nil
            state = .idle
        }
    }

    public func clearLastError() {
        lastErrorMessage = nil
        if case .failed = state {
            state = .idle
        }
    }

    public func loadProducts() async {
        guard !isLoadingProducts else { return }

        state = .loading
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            products = try await Product.products(for: productIDs)
            if products.isEmpty {
                setFailure("No purchasable product found. Check App Store Connect product ID and status.")
            } else {
                state = .idle
            }
        } catch {
            setFailure(error.localizedDescription)
        }
    }

    public func purchaseFirstAvailableProduct() async {
        if products.isEmpty {
            await loadProducts()
        }
        guard let product = products.first else { return }
        await purchase(product)
    }

    public func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verify(verification)
                await transaction.finish()
                trialManager.unlock()
                lastErrorMessage = nil
                state = .idle
            case .pending:
                setFailure("Purchase is pending approval.")
            case .userCancelled:
                state = .idle
            @unknown default:
                setFailure("Unknown purchase state.")
            }
        } catch {
            setFailure(error.localizedDescription)
        }
    }

    public func restore() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(_) = result {
                trialManager.unlock()
                found = true
            }
        }

        if found {
            lastErrorMessage = nil
            state = .idle
        } else {
            setFailure("No previous purchase found to restore.")
        }
    }

    private func setFailure(_ message: String) {
        lastErrorMessage = message
        state = .failed(message)
    }

    private func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "PurchaseManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Purchase verification failed."])
        case .verified(let signed):
            return signed
        }
    }
}
