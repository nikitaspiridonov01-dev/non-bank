import type { Category, CurrencyCode, Transaction } from '../context/TransactionsContext';

type PersistedTransaction = Omit<Transaction, 'date'> & {
  date: string;
};

type PersistedAppState = {
  transactions: PersistedTransaction[];
  categories: Category[];
  selectedCurrency: CurrencyCode;
  usdRates: Record<CurrencyCode, number>;
};

type PersistedRecord = {
  key: string;
  value: PersistedAppState;
};

const DB_NAME = 'myApp';
const DB_VERSION = 1;
const STORE_NAME = 'appState';
const APP_STATE_KEY = 'transactions-context';

const isIndexedDbAvailable = () => typeof indexedDB !== 'undefined';

const openDatabase = async (): Promise<IDBDatabase | null> => {
  if (!isIndexedDbAvailable()) {
    return null;
  }

  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const db = request.result;

      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: 'key' });
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('Failed to open IndexedDB'));
  });
};

const runRequest = async <T>(request: IDBRequest<T>): Promise<T> => new Promise((resolve, reject) => {
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error ?? new Error('IndexedDB request failed'));
});

const awaitTransaction = async (transaction: IDBTransaction): Promise<void> => new Promise((resolve, reject) => {
  transaction.oncomplete = () => resolve();
  transaction.onerror = () => reject(transaction.error ?? new Error('IndexedDB transaction failed'));
  transaction.onabort = () => reject(transaction.error ?? new Error('IndexedDB transaction aborted'));
});

export const loadPersistedAppState = async (): Promise<PersistedAppState | null> => {
  const db = await openDatabase();

  if (!db) {
    return null;
  }

  try {
    const transaction = db.transaction(STORE_NAME, 'readonly');
    const store = transaction.objectStore(STORE_NAME);
    const record = await runRequest(store.get(APP_STATE_KEY) as IDBRequest<PersistedRecord | undefined>);
    await awaitTransaction(transaction);
    return record?.value ?? null;
  } finally {
    db.close();
  }
};

export const savePersistedAppState = async (state: PersistedAppState): Promise<void> => {
  const db = await openDatabase();

  if (!db) {
    return;
  }

  try {
    const transaction = db.transaction(STORE_NAME, 'readwrite');
    const store = transaction.objectStore(STORE_NAME);
    store.put({ key: APP_STATE_KEY, value: state });
    await awaitTransaction(transaction);
  } finally {
    db.close();
  }
};
