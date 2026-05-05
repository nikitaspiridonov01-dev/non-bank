import Foundation
import Combine

class CurrencyStore: ObservableObject {
    // Для динамической сортировки валют
    private var transactions: [Transaction] = []

    private let selectedCurrencyKey = "selectedCurrency"
    private let usdRatesKey = "usdRates"
    private let ratesCacheDateKey = "ratesCacheDate"
    private let store: KeyValueStoreProtocol
    private let converter: CurrencyServiceProtocol
    private let api: CurrencyAPIProtocol

    init(
        store: KeyValueStoreProtocol = UserDefaultsService(),
        converter: CurrencyServiceProtocol = CurrencyService(),
        api: CurrencyAPIProtocol = CurrencyAPI()
    ) {
        self.store = store
        self.converter = converter
        self.api = api
        // Восстановление из store
        if let savedCurrency = self.store.string(forKey: selectedCurrencyKey) {
            self.selectedCurrency = savedCurrency
        }
        if let data = self.store.data(forKey: usdRatesKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            self.usdRates = decoded
        }
        setupPersistence()
        fetchIfNeeded()
    }

    // Сохранять selectedCurrency при изменении
    private var currencyCancellable: AnyCancellable?
    private var ratesCancellable: AnyCancellable?

    func setupPersistence() {
        currencyCancellable = $selectedCurrency.sink { [weak self] value in
            guard let self else { return }
            self.store.set(value, forKey: self.selectedCurrencyKey)
        }
        ratesCancellable = $usdRates.sink { [weak self] value in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(value) {
                self.store.set(data, forKey: self.usdRatesKey)
            }
        }
    }

    // MARK: - Caching

    private var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var isCacheValid: Bool {
        guard let cached = store.string(forKey: ratesCacheDateKey) else { return false }
        return cached == todayString
    }

    /// Fetch rates and currency names if cache is stale (older than today)
    func fetchIfNeeded() {
        guard !isCacheValid else { return }
        fetchRatesFrankfurter()
    }

    /// Конвертация из USD в target
    func convertFromUsd(amount: Double, to: String) -> Double {
        converter.convertFromUsd(amount: amount, to: to, rates: usdRates)
    }

    /// Конвертация из source в USD
    func convertToUsd(amount: Double, from: String) -> Double {
        converter.convertToUsd(amount: amount, from: from, rates: usdRates)
    }

    /// Загрузка курсов валют с Frankfurter API (USD base)
    func fetchRatesFrankfurter(completion: ((Bool) -> Void)? = nil) {
        Task {
            do {
                let rates = try await api.fetchLatestRates(base: "USD")
                await MainActor.run {
                    // Merge new rates into existing (keeps cached values for missing keys)
                    for (key, value) in rates {
                        self.usdRates[key] = value
                    }
                    // Mark cache as valid for today
                    self.store.set(self.todayString, forKey: self.ratesCacheDateKey)
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    completion?(false)
                }
            }
        }
    }

    @Published var selectedCurrency: String = "USD"

    /// usdRates: [Код валюты: курс к USD]
    @Published var usdRates: [String: Double] = [
        "USD": 1.0,
        "EUR": 0.92,
        "RUB": 84.0,
        "KZT": 450.0,
        "UAH": 39.0,
        "BYN": 3.2,
        "TRY": 32.0,
        "GBP": 0.79,
        "JPY": 151.0,
        "CNY": 7.2
    ]

    /// Список валют для выбора (динамическая сортировка)
    var currencyOptions: [String] {
        let allCodes = CurrencyInfo.catalog.map { $0.code }
        let base = selectedCurrency
        // 1. Base currency always first
        // 2. Remaining sorted by usage frequency, then most recent, then alphabetically
        var freq: [String: Int] = [:]
        var lastDate: [String: Date] = [:]
        for tx in transactions {
            freq[tx.currency, default: 0] += 1
            if let prev = lastDate[tx.currency] {
                if tx.date > prev { lastDate[tx.currency] = tx.date }
            } else {
                lastDate[tx.currency] = tx.date
            }
        }
        let rest = allCodes.filter { $0 != base }.sorted { a, b in
            let fa = freq[a, default: 0], fb = freq[b, default: 0]
            if fa != fb { return fa > fb }
            let da = lastDate[a] ?? .distantPast, db = lastDate[b] ?? .distantPast
            if da != db { return da > db }
            return a < b
        }
        return [base] + rest
    }

    /// Обновить список транзакций для сортировки валют
    func updateTransactions(_ txs: [Transaction]) {
        self.transactions = txs
        objectWillChange.send() // чтобы обновить currencyOptions
    }

    /// Универсальная конвертация между любыми валютами через USD
    func convert(amount: Double, from: String, to: String) -> Double {
        converter.convert(amount: amount, from: from, to: to, rates: usdRates)
    }
}
