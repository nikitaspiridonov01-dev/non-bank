import React, { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { loadPersistedAppState, savePersistedAppState } from '../utils/appPersistence';

export type CurrencyCode = string;

export type Transaction = {
  id: number;
  emoji: string;
  category: string;
  title: string;
  description: string;
  amount: number;
  currency: CurrencyCode;
  date: Date;
  type: string;
  isIncome: boolean;
  tags: string[];
};

export type CurrencyOption = {
  code: CurrencyCode;
  label: string;
  name: string;
  emoji: string;
};

export type Category = {
  emoji: string;
  title: string;
};

const DEFAULT_CATEGORIES: Category[] = [
  { emoji: '💻', title: 'Work' },
  { emoji: '💸', title: 'Fee' },
  { emoji: '🚕', title: 'Transport' },
  { emoji: '🍔', title: 'Food' },
  { emoji: '🛍️', title: 'Shopping' },
  { emoji: '🎮', title: 'Entertainment' },
  { emoji: '✈️', title: 'Travel' },
  { emoji: '💰', title: 'Income' },
];

const CURRENCY_META: Record<string, { name: string; emoji: string }> = {
  USD: { name: 'US Dollar', emoji: '🇺🇸' },
  EUR: { name: 'Euro', emoji: '🇪🇺' },
  RUB: { name: 'Russian Ruble', emoji: '🇷🇺' },
  AUD: { name: 'Australian Dollar', emoji: '🇦🇺' },
  BGN: { name: 'Bulgarian Lev', emoji: '🇧🇬' },
  BRL: { name: 'Brazilian Real', emoji: '🇧🇷' },
  CAD: { name: 'Canadian Dollar', emoji: '🇨🇦' },
  CHF: { name: 'Swiss Franc', emoji: '🇨🇭' },
  CNY: { name: 'Chinese Yuan', emoji: '🇨🇳' },
  CZK: { name: 'Czech Koruna', emoji: '🇨🇿' },
  DKK: { name: 'Danish Krone', emoji: '🇩🇰' },
  GBP: { name: 'British Pound', emoji: '🇬🇧' },
  HKD: { name: 'Hong Kong Dollar', emoji: '🇭🇰' },
  HUF: { name: 'Hungarian Forint', emoji: '🇭🇺' },
  IDR: { name: 'Indonesian Rupiah', emoji: '🇮🇩' },
  ILS: { name: 'Israeli New Shekel', emoji: '🇮🇱' },
  INR: { name: 'Indian Rupee', emoji: '🇮🇳' },
  ISK: { name: 'Icelandic Krona', emoji: '🇮🇸' },
  JPY: { name: 'Japanese Yen', emoji: '🇯🇵' },
  KRW: { name: 'South Korean Won', emoji: '🇰🇷' },
  MXN: { name: 'Mexican Peso', emoji: '🇲🇽' },
  MYR: { name: 'Malaysian Ringgit', emoji: '🇲🇾' },
  NOK: { name: 'Norwegian Krone', emoji: '🇳🇴' },
  NZD: { name: 'New Zealand Dollar', emoji: '🇳🇿' },
  PHP: { name: 'Philippine Peso', emoji: '🇵🇭' },
  PLN: { name: 'Polish Zloty', emoji: '🇵🇱' },
  RON: { name: 'Romanian Leu', emoji: '🇷🇴' },
  SEK: { name: 'Swedish Krona', emoji: '🇸🇪' },
  SGD: { name: 'Singapore Dollar', emoji: '🇸🇬' },
  THB: { name: 'Thai Baht', emoji: '🇹🇭' },
  TRY: { name: 'Turkish Lira', emoji: '🇹🇷' },
  ZAR: { name: 'South African Rand', emoji: '🇿🇦' },
};

const FALLBACK_USD_RATES: Record<CurrencyCode, number> = {
  USD: 1,
  EUR: 0.87,
  RUB: 84,
};

const buildCurrencyOptions = (rates: Record<CurrencyCode, number>): CurrencyOption[] => {
  const codes = Object.keys(rates)
    .filter((code) => Number.isFinite(rates[code]) && rates[code] > 0)
    .sort((a, b) => {
      if (a === 'USD') return -1;
      if (b === 'USD') return 1;
      return a.localeCompare(b);
    });

  return codes.map((code) => {
    const meta = CURRENCY_META[code];
    const emoji = meta?.emoji ?? '🌐';
    const name = meta?.name ?? code;

    return {
      code,
      label: `${code} ${emoji}`,
      name,
      emoji,
    };
  });
};

const getCategoryEmoji = (categoryTitle: string, categories: Category[] = DEFAULT_CATEGORIES): string => {
  const category = categories.find((c) => c.title === categoryTitle);
  return category ? category.emoji : '❓';
};

const validateAndNormalizeTransaction = (tx: Transaction, categories: Category[] = DEFAULT_CATEGORIES): Transaction => {
  const matchedByEmoji = categories.find((c) => c.emoji === tx.emoji);

  if (matchedByEmoji) {
    return {
      ...tx,
      category: matchedByEmoji.title,
    };
  }

  return {
    ...tx,
    category: 'Uncategorized',
    emoji: '❓',
  };
};

const normalizeTransactions = (transactions: Transaction[], categories: Category[] = DEFAULT_CATEGORIES): Transaction[] => transactions
  .map((transaction) => validateAndNormalizeTransaction({
    ...transaction,
    date: transaction.date instanceof Date ? transaction.date : new Date(transaction.date),
  }, categories))
  .sort((a, b) => b.date.getTime() - a.date.getTime());

const mergeCategories = (categories: Category[]) => {
  const merged = [...DEFAULT_CATEGORIES];
  const seen = new Set(DEFAULT_CATEGORIES.map((category) => `${category.emoji}:${category.title}`));

  categories.forEach((category) => {
    const key = `${category.emoji}:${category.title}`;

    if (!seen.has(key)) {
      seen.add(key);
      merged.push(category);
    }
  });

  return merged;
};

const INITIAL_TRANSACTIONS: Transaction[] = [
  { id: 1, emoji: '🍔', category: 'Food', title: 'Lunch', description: 'Restaurant downtown', amount: 12.50, currency: 'USD', date: new Date(2026, 2, 8), type: 'Expenses', isIncome: false, tags: ['обед', 'еда'] },
  { id: 2, emoji: '🚕', category: 'Transport', title: 'Gas', description: 'Shell gas station', amount: 45.00, currency: 'USD', date: new Date(2026, 2, 8), type: 'Expenses', isIncome: false, tags: ['машина'] },
  { id: 3, emoji: '🎮', category: 'Entertainment', title: 'Movie', description: '## Cinema night\nWatched **Dune: Part Two** with friends.\n\n- 2 tickets\n- caramel popcorn\n- late session', amount: 15.99, currency: 'USD', date: new Date(2026, 2, 1), type: 'Expenses', isIncome: false, tags: ['кино', 'развлечения'] },
  { id: 4, emoji: '🛍️', category: 'Shopping', title: 'Books', description: 'Amazon order', amount: 29.99, currency: 'USD', date: new Date(2026, 2, 1), type: 'Expenses', isIncome: false, tags: ['книги', 'шопинг'] },
  { id: 5, emoji: '🍔', category: 'Food', title: 'Coffee', description: 'Starbucks', amount: 5.50, currency: 'USD', date: new Date(2026, 0, 11), type: 'Expenses', isIncome: false, tags: ['кофе', 'обед'] },
  { id: 6, emoji: '🛍️', category: 'Shopping', title: 'Shopping', description: 'H&M clothes', amount: 87.00, currency: 'USD', date: new Date(2026, 2, 8), type: 'Expenses', isIncome: false, tags: ['шопинг', 'одежда'] },
  { id: 7, emoji: '🎮', category: 'Entertainment', title: 'Video game', description: 'Steam store', amount: 59.99, currency: 'USD', date: new Date(2026, 2, 5), type: 'Expenses', isIncome: false, tags: ['игры', 'развлечения'] },
  { id: 8, emoji: '✈️', category: 'Travel', title: 'Flight ticket', description: 'Air travel', amount: 250.00, currency: 'USD', date: new Date(2026, 2, 3), type: 'Expenses', isIncome: false, tags: ['лето', 'путешествие'] },
  { id: 9, emoji: '✈️', category: 'Travel', title: 'Hotel', description: '### Stay details\nBooked via [Booking.com](https://booking.com)\n\n> Early check-in confirmed\n\nRoom: **Double Deluxe**', amount: 120.00, currency: 'EUR', date: new Date(2026, 2, 3), type: 'Expenses', isIncome: false, tags: ['гостиница', 'путешествие'] },
  { id: 10, emoji: '💰', category: 'Income', title: 'Salary', description: '# Monthly salary\nBase compensation for **February**.\n\n- bonus included\n- taxes already withheld\n- payout source: `EU payroll`', amount: 3500.00, currency: 'EUR', date: new Date(2026, 1, 28), type: 'Income', isIncome: true, tags: ['зарплата', 'доход'] },
  { id: 11, emoji: '💸', category: 'Fee', title: 'Service Fee', description: 'Bank service fee', amount: 252.00, currency: 'RUB', date: new Date(2026, 2, 10), type: 'Expenses', isIncome: false, tags: ['комиссия', 'сервис'] },
  { id: 12, emoji: '❓', category: 'Uncategorized', title: 'Chargeback', description: 'Refund for dispute', amount: 29.99, currency: 'USD', date: new Date(2026, 2, 12), type: 'Income', isIncome: true, tags: ['возврат', 'спор'] },
  { id: 13, emoji: '🚕', category: 'Transport', title: 'Taxi', description: 'Trip with Yandex Go\n\nRoute: Tverskaya -> Belorusskaya', amount: 1280.00, currency: 'RUB', date: new Date(2026, 2, 9), type: 'Expenses', isIncome: false, tags: ['такси', 'город'] },
  { id: 14, emoji: '🍔', category: 'Food', title: 'Breakfast', description: 'Cafe in Paris', amount: 18.40, currency: 'EUR', date: new Date(2026, 2, 6), type: 'Expenses', isIncome: false, tags: ['еда', 'поездка'] },
  { id: 15, emoji: '💻', category: 'Work', title: 'New MacBook', description: '# Work Equipment Upgrade\n\nFinally got the new **M3 Max MacBook Pro**! Here are the specs and thoughts:\n\n## Specifications\n- **Chip:** Apple M3 Max with 16-core CPU, 40-core GPU\n- **Memory:** 64GB Unified Memory\n- **Storage:** 2TB SSD\n- **Display:** 16-inch Liquid Retina XDR\n\n## Initial Setup\nIt took me about 3 hours to transfer all my data, configure the development environments, and set up Docker.\n\n### Software Installed:\n1. VS Code\n2. iTerm2\n3. Docker Desktop\n4. Node.js (via nvm)\n5. Python 3.12\n\n> The performance difference compared to my old Mac is staggering. Builds that used to take 5 minutes now finish in under 30 seconds!\n\nOverall, a very worthwhile investment for productivity.', amount: 3499.00, currency: 'USD', date: new Date(2026, 2, 11), type: 'Expenses', isIncome: false, tags: ['работа', 'техника', 'apple'] },
];

type TransactionsContextType = {
  transactions: Transaction[];
  setTransactions: React.Dispatch<React.SetStateAction<Transaction[]>>;
  addTransaction: (transaction: Omit<Transaction, 'id'>) => void;
  updateTransaction: (id: number, transaction: Omit<Transaction, 'id'>) => void;
  deleteTransaction: (id: number) => void;
  selectedCurrency: CurrencyCode;
  setSelectedCurrency: React.Dispatch<React.SetStateAction<CurrencyCode>>;
  enabledCurrencies: CurrencyCode[];
  setEnabledCurrencies: React.Dispatch<React.SetStateAction<CurrencyCode[]>>;
  usdRates: Record<CurrencyCode, number>;
  currencyOptions: CurrencyOption[];
  categories: Category[];
  addCategory: (emoji: string, title: string) => void;
};

const TransactionsContext = createContext<TransactionsContextType | null>(null);

export const TransactionsProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const initialOptions = buildCurrencyOptions(FALLBACK_USD_RATES);
  const [transactions, setTransactions] = useState<Transaction[]>(
    normalizeTransactions(INITIAL_TRANSACTIONS)
  );
  const [usdRates, setUsdRates] = useState<Record<CurrencyCode, number>>(FALLBACK_USD_RATES);
  const [rawCurrencyOptions, setRawCurrencyOptions] = useState<CurrencyOption[]>(initialOptions);
  const [selectedCurrency, setSelectedCurrency] = useState<CurrencyCode>('USD');
  const [enabledCurrencies, setEnabledCurrencies] = useState<CurrencyCode[]>(() => initialOptions.map((option) => option.code));
  const [categories, setCategories] = useState<Category[]>(DEFAULT_CATEGORIES);
  const [isPersistenceHydrated, setIsPersistenceHydrated] = useState(false);

  const currencyOptions = useMemo(() => {
    const initialOrder = new Map(rawCurrencyOptions.map((option, index) => [option.code, index]));
    const stats = new Map<CurrencyCode, { count: number; latestTimestamp: number }>();

    transactions.forEach((transaction) => {
      if (!initialOrder.has(transaction.currency)) {
        return;
      }

      const current = stats.get(transaction.currency) ?? { count: 0, latestTimestamp: 0 };
      const timestamp = new Date(transaction.date).getTime();

      stats.set(transaction.currency, {
        count: current.count + 1,
        latestTimestamp: Math.max(current.latestTimestamp, timestamp),
      });
    });

    return [...rawCurrencyOptions].sort((left, right) => {
      const leftStats = stats.get(left.code);
      const rightStats = stats.get(right.code);
      const leftCount = leftStats?.count ?? 0;
      const rightCount = rightStats?.count ?? 0;

      if (rightCount !== leftCount) {
        return rightCount - leftCount;
      }

      const leftLatest = leftStats?.latestTimestamp ?? 0;
      const rightLatest = rightStats?.latestTimestamp ?? 0;

      if (rightLatest !== leftLatest) {
        return rightLatest - leftLatest;
      }

      return (initialOrder.get(left.code) ?? Number.MAX_SAFE_INTEGER) - (initialOrder.get(right.code) ?? Number.MAX_SAFE_INTEGER);
    });
  }, [rawCurrencyOptions, transactions]);

  const addCategory = (emoji: string, title: string): void => {
    setCategories((prev) => [...prev, { emoji, title }]);
  };

  const addTransaction = (transaction: Omit<Transaction, 'id'>): void => {
    setTransactions((prev) => {
      const nextId = prev.length > 0 ? Math.max(...prev.map((item) => item.id)) + 1 : 1;
      const normalized = validateAndNormalizeTransaction({
        ...transaction,
        id: nextId,
      }, categories);

      return [...prev, normalized].sort((a, b) => b.date.getTime() - a.date.getTime());
    });
  };

  const updateTransaction = (id: number, transaction: Omit<Transaction, 'id'>): void => {
    setTransactions((prev) => prev
      .map((item) => (item.id === id
        ? validateAndNormalizeTransaction({
            ...transaction,
            id,
          }, categories)
        : item))
      .sort((a, b) => b.date.getTime() - a.date.getTime()));
  };

  const deleteTransaction = (id: number): void => {
    setTransactions((prev) => prev.filter((transaction) => transaction.id !== id));
  };

  useEffect(() => {
    let isCancelled = false;

    const hydratePersistedState = async () => {
      try {
        const persistedState = await loadPersistedAppState();

        if (isCancelled || !persistedState) {
          return;
        }

        const nextCategories = Array.isArray(persistedState.categories)
          ? mergeCategories(persistedState.categories)
          : DEFAULT_CATEGORIES;

        if (persistedState.usdRates && Object.keys(persistedState.usdRates).length > 0) {
          setUsdRates(persistedState.usdRates);
          setRawCurrencyOptions(buildCurrencyOptions(persistedState.usdRates));
        }

        if (persistedState.selectedCurrency) {
          setSelectedCurrency(persistedState.selectedCurrency);
        }

        setCategories(nextCategories);
        setTransactions(normalizeTransactions(
          Array.isArray(persistedState.transactions)
            ? persistedState.transactions.map((transaction) => ({
                ...transaction,
                date: new Date(transaction.date),
              }))
            : [],
          nextCategories,
        ));
      } catch (error) {
        console.error('Failed to hydrate app state from IndexedDB:', error);
      } finally {
        if (!isCancelled) {
          setIsPersistenceHydrated(true);
        }
      }
    };

    void hydratePersistedState();

    return () => {
      isCancelled = true;
    };
  }, []);

  useEffect(() => {
    let isCancelled = false;

    const loadUsdRates = async () => {
      try {
        const response = await fetch('https://api.frankfurter.dev/v1/latest?base=USD');
        if (!response.ok) {
          throw new Error(`Request failed with status ${response.status}`);
        }

        const payload = (await response.json()) as { rates?: Record<string, number> };
        const normalized: Record<CurrencyCode, number> = { USD: 1 };

        Object.entries(payload.rates ?? {}).forEach(([code, value]) => {
          const upperCode = code.toUpperCase();
          if (Number.isFinite(value) && value > 0) {
            normalized[upperCode] = value;
          }
        });

        if (isCancelled) {
          return;
        }

        const options = buildCurrencyOptions(normalized);
        setUsdRates(normalized);
        setRawCurrencyOptions(options);
        setEnabledCurrencies(options.map((option) => option.code));
        setSelectedCurrency((prev) => (normalized[prev] ? prev : 'USD'));
      } catch (error) {
        console.error('Failed to load exchange rates from Frankfurter:', error);
      }
    };

    void loadUsdRates();

    return () => {
      isCancelled = true;
    };
  }, []);

  const validEnabledCurrencies = useMemo(
    () => currencyOptions.map((option) => option.code).filter((code) => Boolean(usdRates[code])),
    [currencyOptions, usdRates]
  );

  useEffect(() => {
    if (validEnabledCurrencies.length === 0) {
      return;
    }

    if (!validEnabledCurrencies.includes(selectedCurrency)) {
      setSelectedCurrency(validEnabledCurrencies[0]);
    }
  }, [validEnabledCurrencies, selectedCurrency]);

  useEffect(() => {
    if (!isPersistenceHydrated) {
      return;
    }

    void savePersistedAppState({
      transactions: transactions.map((transaction) => ({
        ...transaction,
        date: (transaction.date instanceof Date ? transaction.date : new Date(transaction.date)).toISOString(),
      })),
      categories,
      selectedCurrency,
      usdRates,
    }).catch((error) => {
      console.error('Failed to persist app state to IndexedDB:', error);
    });
  }, [categories, isPersistenceHydrated, selectedCurrency, transactions, usdRates]);

  return (
    <TransactionsContext.Provider value={{
      transactions,
      setTransactions,
      addTransaction,
      updateTransaction,
      deleteTransaction,
      selectedCurrency,
      setSelectedCurrency,
      enabledCurrencies: validEnabledCurrencies,
      setEnabledCurrencies,
      usdRates,
      currencyOptions,
      categories,
      addCategory,
    }}>
      {children}
    </TransactionsContext.Provider>
  );
};

export const useTransactions = (): TransactionsContextType => {
  const ctx = useContext(TransactionsContext);
  if (!ctx) throw new Error('useTransactions must be used within TransactionsProvider');
  return ctx;
};

export { getCategoryEmoji, validateAndNormalizeTransaction, DEFAULT_CATEGORIES };
