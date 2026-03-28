import React, { useEffect, useMemo, useRef, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import {
  IonContent, IonPage, IonItem, IonLabel, IonNote,
  IonCard, IonCardContent, IonBadge, IonIcon,
  IonItemOption, IonItemOptions, IonItemSliding,
  IonModal, useIonAlert
} from '@ionic/react';
import {
  arrowForward, cartOutline, trendingUpOutline,
  refreshOutline, cardOutline, optionsOutline, searchOutline,
  chevronBackOutline, chevronForwardOutline, createOutline, trashOutline
} from 'ionicons/icons';
import './Home.css';
import { useTransactions, Transaction, CurrencyCode } from '../context/TransactionsContext';
import CreateTransactionModal from '../components/CreateTransactionModal';

type DateFilterType = 'all' | 'today' | 'week' | 'month' | 'year';

const DATE_FILTER_OPTIONS: Array<{ value: DateFilterType; label: string }> = [
  { value: 'all', label: 'All time' },
  { value: 'today', label: 'Today' },
  { value: 'week', label: 'This week' },
  { value: 'month', label: 'This month' },
  { value: 'year', label: 'This year' },
];

const getPlainDescription = (description: string) => description
  .replace(/```[\s\S]*?```/g, ' ')
  .replace(/`([^`]+)`/g, '$1')
  .replace(/!?\[([^\]]+)\]\([^\)]+\)/g, '$1')
  .replace(/^#{1,6}\s+/gm, '')
  .replace(/[*_~>#-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

const toLocalDateKey = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

const getUsdRate = (rates: Record<CurrencyCode, number>, currency: CurrencyCode) => rates[currency] ?? 1;

const getStartOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate());

const getEndOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999);

const getStartOfMonth = (date: Date) => new Date(date.getFullYear(), date.getMonth(), 1);

const getEndOfMonth = (date: Date) => new Date(date.getFullYear(), date.getMonth() + 1, 0, 23, 59, 59, 999);

const getStartOfYear = (date: Date) => new Date(date.getFullYear(), 0, 1);

const getEndOfYear = (date: Date) => new Date(date.getFullYear(), 11, 31, 23, 59, 59, 999);

const isDateOnlyTrendFilter = (filter: DateFilterType) => filter === 'all' || filter === 'year';

const formatTrendBarLabel = (date: Date, filter: DateFilterType) => {
  if (isDateOnlyTrendFilter(filter)) {
    return date.toLocaleDateString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  }

  return date.toLocaleString('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

const getTrendFallbackRange = (filter: DateFilterType, referenceDate = new Date()) => {
  switch (filter) {
    case 'today':
      return {
        startMs: getStartOfDay(referenceDate).getTime(),
        endMs: getEndOfDay(referenceDate).getTime(),
      };
    case 'week': {
      const start = getStartOfDay(referenceDate);
      start.setDate(start.getDate() - 7);
      return {
        startMs: start.getTime(),
        endMs: getEndOfDay(referenceDate).getTime(),
      };
    }
    case 'month':
      return {
        startMs: getStartOfMonth(referenceDate).getTime(),
        endMs: getEndOfMonth(referenceDate).getTime(),
      };
    case 'year':
      return {
        startMs: getStartOfYear(referenceDate).getTime(),
        endMs: getEndOfYear(referenceDate).getTime(),
      };
    case 'all':
    default: {
      const end = getEndOfDay(referenceDate);
      const start = new Date(end);
      start.setDate(start.getDate() - 43);
      start.setHours(0, 0, 0, 0);
      return {
        startMs: start.getTime(),
        endMs: end.getTime(),
      };
    }
  }
};

const Home: React.FC = () => {
  const { transactions, deleteTransaction, selectedCurrency, setSelectedCurrency, usdRates, currencyOptions } = useTransactions();

  const contentRef = useRef<HTMLIonContentElement>(null);
  const collapseSentinelRef = useRef<HTMLDivElement>(null);
  const balanceStickyRef = useRef<HTMLDivElement>(null);
  const transactionDateSectionRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const isCollapsedRef = useRef(false);
  
  const [selectedTransaction, setSelectedTransaction] = useState<Transaction | null>(null);
  const [showTransactionModal, setShowTransactionModal] = useState(false);
  const [editingTransaction, setEditingTransaction] = useState<Transaction | null>(null);
  const [isEditTransactionOpen, setIsEditTransactionOpen] = useState(false);
  
  const [balanceDateFilter, setBalanceDateFilter] = useState<DateFilterType>('all');
  const [hoveredBarIdx, setHoveredBarIdx] = useState<number | null>(null);
  
  // ФИЛЬТРЫ
  const [filterCategories, setFilterCategories] = useState<string[]>([]);
  const [filterTypes, setFilterTypes] = useState<string[]>([]);
  const [filterTags, setFilterTags] = useState<string[]>([]);
  
  // СОСТОЯНИЯ ШТОРОК
  const [isFilterSheetOpen, setIsFilterSheetOpen] = useState(false);
  const [isDatePickerOpen, setIsDatePickerOpen] = useState(false);
  const [isSearchModalOpen, setIsSearchModalOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [expandedFilters, setExpandedFilters] = useState({ category: false, type: false, tag: false });
  const [calendarMonth, setCalendarMonth] = useState(() => {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1);
  });

  const [presentAlert] = useIonAlert();

  const isSafariBrowser = useMemo(() => {
    if (typeof navigator === 'undefined') {
      return false;
    }

    const ua = navigator.userAgent;
    return /Safari/i.test(ua) && !/Chrome|Chromium|CriOS|Edg|EdgiOS|OPR|OPiOS|Firefox|FxiOS/i.test(ua);
  }, []);

  useEffect(() => {
    let destroyed = false;
    let observer: IntersectionObserver | null = null;

    const setup = async () => {
      const contentEl = contentRef.current;
      const sentinelEl = collapseSentinelRef.current;
      if (!contentEl || !sentinelEl) {
        return;
      }

      const scrollRoot = await contentEl.getScrollElement();
      if (destroyed) {
        return;
      }

      observer = new IntersectionObserver(
        ([entry]) => {
          const shouldCollapse = !entry.isIntersecting;
          if (shouldCollapse !== isCollapsedRef.current && balanceStickyRef.current) {
            balanceStickyRef.current.classList.toggle('is-collapsed', shouldCollapse);
            isCollapsedRef.current = shouldCollapse;
          }
        },
        {
          root: scrollRoot,
          threshold: 0,
        }
      );

      observer.observe(sentinelEl);
    };

    setup();

    return () => {
      destroyed = true;
      observer?.disconnect();
    };
  }, []);

  useEffect(() => {
    if (!selectedTransaction) {
      return;
    }

    const nextSelectedTransaction = transactions.find((transaction) => transaction.id === selectedTransaction.id) ?? null;

    if (!nextSelectedTransaction) {
      setSelectedTransaction(null);
      setShowTransactionModal(false);
      return;
    }

    if (nextSelectedTransaction !== selectedTransaction) {
      setSelectedTransaction(nextSelectedTransaction);
    }
  }, [selectedTransaction, transactions]);

  const getFilteredTransactions = (filter: DateFilterType): Transaction[] => {
    if (filter === 'all') return transactions;
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    return transactions.filter((tx) => {
      const txDate = tx.date instanceof Date ? tx.date : new Date(tx.date);
      const txDateOnly = new Date(txDate.getFullYear(), txDate.getMonth(), txDate.getDate());

      switch (filter) {
        case 'today': return txDateOnly.getTime() === today.getTime();
        case 'week': {
          const weekAgo = new Date(today);
          weekAgo.setDate(weekAgo.getDate() - 7);
          return txDateOnly.getTime() >= weekAgo.getTime() && txDateOnly.getTime() <= today.getTime();
        }
        case 'month': return txDate.getFullYear() === now.getFullYear() && txDate.getMonth() === now.getMonth();
        case 'year': return txDate.getFullYear() === now.getFullYear();
        default: return true;
      }
    });
  };

  const convertFromUsd = (amountInUsd: number, currency: CurrencyCode = selectedCurrency) => amountInUsd * getUsdRate(usdRates, currency);
  const convertToUsd = (amount: number, currency: CurrencyCode) => amount / getUsdRate(usdRates, currency);

  const totalBalanceInUsd = convertToUsd(
    getFilteredTransactions(balanceDateFilter).reduce((sum, tx) => sum + (tx.isIncome ? tx.amount : -tx.amount), 0), 
    'USD'
  );

  type TrendBarPoint = { height: number; balanceUsd: number; label: string };

  const balanceTrendBars = useMemo((): TrendBarPoint[] => {
    const POINTS_COUNT = 44;
    const filteredTxs = getFilteredTransactions(balanceDateFilter);

    const entries = filteredTxs
      .map((tx) => {
        const timestamp = (tx.date instanceof Date ? tx.date : new Date(tx.date)).getTime();
        const signedAmountUsd = convertToUsd(tx.isIncome ? tx.amount : -tx.amount, tx.currency);
        return { timestamp, signedAmountUsd };
      })
      .sort((a, b) => a.timestamp - b.timestamp);

    let startMs: number;
    let endMs: number;

    if (entries.length > 0) {
      const firstDate = new Date(entries[0].timestamp);
      const lastDate = new Date(entries[entries.length - 1].timestamp);

      if (isDateOnlyTrendFilter(balanceDateFilter)) {
        startMs = getStartOfDay(firstDate).getTime();
        endMs = getStartOfDay(lastDate).getTime();
      } else {
        startMs = entries[0].timestamp;
        endMs = entries[entries.length - 1].timestamp;
      }
    } else {
      const fallback = getTrendFallbackRange(balanceDateFilter, entries[0] ? new Date(entries[0].timestamp) : new Date());
      startMs = fallback.startMs;
      endMs = fallback.endMs;
    }

    const stepMs = POINTS_COUNT > 1 ? (endMs - startMs) / (POINTS_COUNT - 1) : 0;
    const points = Array.from({ length: POINTS_COUNT }, (_, index) => {
      const pointMs = startMs + stepMs * index;
      const pointDate = new Date(pointMs);
      const lookupMs = isDateOnlyTrendFilter(balanceDateFilter)
        ? getEndOfDay(pointDate).getTime()
        : pointMs;

      return {
        pointMs,
        lookupMs,
        label: formatTrendBarLabel(pointDate, balanceDateFilter),
      };
    });

    let runningBalanceUsd = 0;
    let entryIndex = 0;
    const filledPoints = points.map((point) => {
      while (entryIndex < entries.length && entries[entryIndex].timestamp <= point.lookupMs) {
        runningBalanceUsd += entries[entryIndex].signedAmountUsd;
        entryIndex += 1;
      }

      return {
        label: point.label,
        balanceUsd: runningBalanceUsd,
      };
    });

    const values = filledPoints.map((point) => point.balanceUsd);
    const min = Math.min(...values);
    const max = Math.max(...values);
    const range = max - min;

    return filledPoints.map((point) => ({
      height: range === 0 ? 12 : Math.round(6 + ((point.balanceUsd - min) / range) * 58),
      balanceUsd: point.balanceUsd,
      label: point.label,
    }));
  }, [balanceDateFilter, transactions, usdRates]);

  const totalBalance = convertFromUsd(
    hoveredBarIdx !== null ? balanceTrendBars[hoveredBarIdx]?.balanceUsd ?? totalBalanceInUsd : totalBalanceInUsd
  );

  const handleTrendHover = (event: React.MouseEvent<HTMLDivElement>) => {
    if (balanceTrendBars.length === 0) {
      return;
    }

    const rect = event.currentTarget.getBoundingClientRect();
    if (!rect.width) {
      return;
    }

    const offsetX = Math.min(Math.max(event.clientX - rect.left, 0), rect.width);
    const nextIndex = Math.min(
      balanceTrendBars.length - 1,
      Math.max(0, Math.round((offsetX / rect.width) * (balanceTrendBars.length - 1)))
    );

    setHoveredBarIdx((prev) => (prev === nextIndex ? prev : nextIndex));
  };

  const categoryOptions = useMemo(() => {
    const map = new Map<string, string>();
    transactions.forEach(tx => { if (!map.has(tx.category)) map.set(tx.category, tx.emoji); });
    return Array.from(map.entries()).sort(([a], [b]) => a.localeCompare(b));
  }, [transactions]);

  const typeOptions = useMemo(() => [...new Set(transactions.map(t => t.type))].sort(), [transactions]);

  const sortedTagsByFrequency = useMemo(() => {
    const freq = new Map<string, number>();
    transactions.forEach(tx => tx.tags.forEach(tag => freq.set(tag, (freq.get(tag) ?? 0) + 1)));
    return [...freq.entries()].sort((a, b) => b[1] - a[1]).map(([tag]) => tag);
  }, [transactions]);

  const sortedCategoriesByFreq = useMemo(() => {
    const freq = new Map<string, number>();
    transactions.forEach(tx => freq.set(tx.category, (freq.get(tx.category) ?? 0) + 1));
    return categoryOptions
      .map(([cat, emoji]) => ({ cat, emoji }))
      .sort((a, b) => (freq.get(b.cat) ?? 0) - (freq.get(a.cat) ?? 0));
  }, [transactions, categoryOptions]);

  const sortedTypesByFreq = useMemo(() => {
    const freq = new Map<string, number>();
    transactions.forEach(tx => freq.set(tx.type, (freq.get(tx.type) ?? 0) + 1));
    return typeOptions.slice().sort((a, b) => (freq.get(b) ?? 0) - (freq.get(a) ?? 0));
  }, [transactions, typeOptions]);

  const transactionDateKeys = useMemo(() => {
    const keys = Array.from(new Set(transactions.map((tx) => toLocalDateKey(tx.date instanceof Date ? tx.date : new Date(tx.date)))));
    keys.sort((a, b) => a.localeCompare(b));
    return keys;
  }, [transactions]);

  const transactionDateKeySet = useMemo(() => new Set(transactionDateKeys), [transactionDateKeys]);

  const calendarMinMonth = useMemo(() => {
    if (!transactionDateKeys.length) {
      return null;
    }
    const [year, month] = transactionDateKeys[0].split('-').map(Number);
    return new Date(year, month - 1, 1);
  }, [transactionDateKeys]);

  const calendarMaxMonth = useMemo(() => {
    if (!transactionDateKeys.length) {
      return null;
    }
    const [year, month] = transactionDateKeys[transactionDateKeys.length - 1].split('-').map(Number);
    return new Date(year, month - 1, 1);
  }, [transactionDateKeys]);

  const calendarCells = useMemo(() => {
    const year = calendarMonth.getFullYear();
    const month = calendarMonth.getMonth();
    const firstDay = new Date(year, month, 1);
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const firstWeekday = (firstDay.getDay() + 6) % 7;

    const cells: Array<{ dateKey: string | null; day: number | null; hasTransactions: boolean }> = [];

    for (let i = 0; i < firstWeekday; i += 1) {
      cells.push({ dateKey: null, day: null, hasTransactions: false });
    }

    for (let day = 1; day <= daysInMonth; day += 1) {
      const dateKey = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      cells.push({ dateKey, day, hasTransactions: transactionDateKeySet.has(dateKey) });
    }

    const trailing = (7 - (cells.length % 7)) % 7;
    for (let i = 0; i < trailing; i += 1) {
      cells.push({ dateKey: null, day: null, hasTransactions: false });
    }

    return cells;
  }, [calendarMonth, transactionDateKeySet]);

  const displayedTransactions = useMemo(() =>
    transactions.filter(tx => {
      if (filterCategories.length > 0 && !filterCategories.includes(tx.category)) return false;
      if (filterTypes.length > 0 && !filterTypes.includes(tx.type)) return false;
      if (filterTags.length > 0 && !filterTags.some(tag => tx.tags.includes(tag))) return false;
      return true;
    }),
    [transactions, filterCategories, filterTypes, filterTags]
  );

  const normalizedSearchQuery = searchQuery.trim().toLowerCase();

  const searchResults = useMemo(() => {
    if (!normalizedSearchQuery) {
      return [];
    }

    return transactions.filter((tx) => {
      const titleMatch = tx.title.toLowerCase().includes(normalizedSearchQuery);
      const notesMatch = getPlainDescription(tx.description).toLowerCase().includes(normalizedSearchQuery);
      return titleMatch || notesMatch;
    });
  }, [transactions, normalizedSearchQuery]);

  const hasActiveFilters = filterCategories.length > 0 || filterTypes.length > 0 || filterTags.length > 0;

  const groupedTransactions = useMemo(() =>
    displayedTransactions.reduce((acc, transaction) => {
      const dateObj = transaction.date instanceof Date ? transaction.date : new Date(transaction.date);
      const dateKey = dateObj.toLocaleDateString('en-US', { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' }).toUpperCase();
      if (!acc[dateKey]) acc[dateKey] = [];
      acc[dateKey].push({ ...transaction, date: dateObj });
      return acc;
    }, {} as Record<string, typeof transactions>),
    [displayedTransactions]
  );

  const getTypeIcon = (type: string) => {
    if (type === 'Expenses') return cartOutline;
    if (type === 'Income') return trendingUpOutline;
    return arrowForward;
  };

  const getTypeBadgeClass = (type: string) => {
    if (type === 'Expenses') return 'badge-purchase';
    if (type === 'Income') return 'badge-income';
    return 'badge-transfer';
  };

  const getTypeFilterClass = (type: string) => {
    if (type === 'Expenses') return 'tx-type-purchase';
    if (type === 'Income') return 'tx-type-income';
    return 'tx-type-transfer';
  };

  const getAmountSign = (isIncome: boolean) => isIncome ? '+' : '-';
  const getBalanceSign = (value: number) => value > 0 ? '+' : value < 0 ? '-' : '';
  const splitAmount = (amount: number) => {
    const [integer, decimal] = amount.toFixed(2).split('.');
    return { integer: Number(integer).toLocaleString('ru-RU'), decimal };
  };

  const handleTransactionClick = (transaction: Transaction) => {
    setSelectedTransaction(transaction);
    setShowTransactionModal(true);
  };

  const handleEditTransaction = (transaction: Transaction) => {
    setEditingTransaction(transaction);
    setShowTransactionModal(false);
    setIsEditTransactionOpen(true);
  };

  const handleCloseSearchModal = () => {
    setIsSearchModalOpen(false);
    setSearchQuery('');
  };

  const handleSearchResultClick = (transaction: Transaction) => {
    handleTransactionClick(transaction);
  };

  const handleDeleteTransaction = async (
    transaction: Transaction,
    slidingItem?: HTMLIonItemSlidingElement | null
  ) => {
    await slidingItem?.close();

    presentAlert({
      header: 'Delete transaction',
      message: `Delete transaction "${transaction.title}"?`,
      buttons: [
        {
          text: 'Cancel',
          role: 'cancel',
        },
        {
          text: 'Delete',
          role: 'destructive',
          handler: () => {
            deleteTransaction(transaction.id);
            if (selectedTransaction?.id === transaction.id) {
              setShowTransactionModal(false);
              setSelectedTransaction(null);
            }
          },
        },
      ],
    });
  };

  const jumpToDateInList = async (dateKey: string) => {
    const targetSection = transactionDateSectionRefs.current.get(dateKey);
    const contentEl = contentRef.current;
    if (!targetSection || !contentEl) {
      return;
    }

    const scrollRoot = await contentEl.getScrollElement();
    const targetRect = targetSection.getBoundingClientRect();
    const rootRect = scrollRoot.getBoundingClientRect();
    const stickyHeight = balanceStickyRef.current?.getBoundingClientRect().height ?? 0;
    const targetTop = scrollRoot.scrollTop + (targetRect.top - rootRect.top) - stickyHeight - 8;
    const y = Math.max(0, targetTop);
    contentEl.scrollToPoint(0, y, 360);
  };

  const handlePickDateClick = () => {
    if (!transactionDateKeys.length) {
      return;
    }

    const [lastYear, lastMonth] = transactionDateKeys[transactionDateKeys.length - 1].split('-').map(Number);
    setCalendarMonth(new Date(lastYear, lastMonth - 1, 1));
    setIsDatePickerOpen(true);
  };

  const handleDatePick = (dateKey: string) => {
    if (!transactionDateKeySet.has(dateKey)) {
      return;
    }

    setIsDatePickerOpen(false);
    setIsFilterSheetOpen(false);
    window.setTimeout(() => {
      void jumpToDateInList(dateKey);
    }, 280);
  };

  const handlePrevMonth = () => {
    setCalendarMonth((prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1));
  };

  const handleNextMonth = () => {
    setCalendarMonth((prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1));
  };

  const monthTitle = useMemo(
    () => calendarMonth.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }),
    [calendarMonth]
  );

  const isPrevMonthDisabled = useMemo(() => {
    if (!calendarMinMonth) {
      return true;
    }
    return calendarMonth.getFullYear() === calendarMinMonth.getFullYear()
      && calendarMonth.getMonth() === calendarMinMonth.getMonth();
  }, [calendarMonth, calendarMinMonth]);

  const isNextMonthDisabled = useMemo(() => {
    if (!calendarMaxMonth) {
      return true;
    }
    return calendarMonth.getFullYear() === calendarMaxMonth.getFullYear()
      && calendarMonth.getMonth() === calendarMaxMonth.getMonth();
  }, [calendarMonth, calendarMaxMonth]);

  const formatDateWithTime = (date: Date | string) => {
    const d = date instanceof Date ? date : new Date(date);
    return d.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  const formatDateBeautifully = (date: Date | string) => {
    const d = date instanceof Date ? date : new Date(date);
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
  };

  const formatTransactionDate = (date: Date) => {
    const now = new Date();
    if (date.getFullYear() === now.getFullYear()) {
      return date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
    }
    return date.toLocaleDateString('en-US', { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' });
  };

  const toggleCategory = (cat: string) => setFilterCategories(prev => prev.includes(cat) ? prev.filter(c => c !== cat) : [...prev, cat]);
  const toggleType = (type: string) => setFilterTypes(prev => prev.includes(type) ? prev.filter(t => t !== type) : [...prev, type]);
  const toggleTag = (tag: string) => setFilterTags(prev => prev.includes(tag) ? prev.filter(t => t !== tag) : [...prev, tag]);

  const VISIBLE_FILTER_LIMIT = 6;

  return (
    <IonPage>
      <IonContent ref={contentRef} fullscreen className={isSafariBrowser ? 'safari-optimized' : ''}>
        <div ref={collapseSentinelRef} className="balance-collapse-sentinel" aria-hidden="true" />
        <div
          ref={balanceStickyRef}
          className="balance-sticky-wrapper"
        >
          <IonCard className="balance-card">
            <IonCardContent className="no-padding">
              <div className="balance-container">
                <div className="balance-main">
                  <div className="balance-header">
                    <span className="balance-label">Net total</span>
                    <select
                      className="balance-date-filter"
                      value={balanceDateFilter}
                      onChange={(e) => setBalanceDateFilter(e.target.value as DateFilterType)}
                    >
                      {DATE_FILTER_OPTIONS.map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                    </select>
                  </div>
                  <div className="balance-amount-row">
                    <div className="balance-amount">
                      <span className="balance-value">
                        <span className="amount-sign">{totalBalance === 0 ? '-' : getBalanceSign(totalBalance)}</span>
                        <span className="amount-integer">{splitAmount(Math.abs(totalBalance)).integer}</span>
                        <span className="amount-decimal">.{splitAmount(Math.abs(totalBalance)).decimal}</span>
                      </span>
                      <label className="balance-currency-picker">
                        <span className="balance-currency-text">{selectedCurrency}</span>
                        <select className="balance-currency-select" value={selectedCurrency} onChange={(e) => setSelectedCurrency(e.target.value as CurrencyCode)}>
                          {currencyOptions.map((currency) => (
                            <option key={currency.code} value={currency.code}>{currency.label}</option>
                          ))}
                        </select>
                      </label>
                    </div>
                  </div>
                </div>
                <div className="balance-trend-wrapper">
                  <div className="balance-trend" onMouseMove={handleTrendHover} onMouseLeave={() => setHoveredBarIdx(null)}>
                    {balanceTrendBars.map((bar, idx) => (
                      <span key={`${idx}`} className={`trend-bar ${hoveredBarIdx === idx ? 'hovered' : hoveredBarIdx !== null ? 'dimmed' : idx > balanceTrendBars.length - 10 ? 'recent' : ''}`} style={{ height: bar.height }} />
                    ))}
                  </div>
                  <div className="balance-trend-date" style={{ visibility: hoveredBarIdx !== null ? 'visible' : 'hidden' }}>
                    {hoveredBarIdx !== null ? balanceTrendBars[hoveredBarIdx]?.label ?? '\u00a0' : '\u00a0'}
                  </div>
                </div>
              </div>
            </IonCardContent>
          </IonCard>

          {hasActiveFilters && (
            <div className="tx-active-filters-sticky">
              <div className="tx-active-filters-bar">
                {filterCategories.map(cat => {
                  const emoji = categoryOptions.find(([c]) => c === cat)?.[1] ?? '';
                  return (
                    <button key={cat} className="tx-active-chip" onClick={() => toggleCategory(cat)}>
                      {emoji} {cat} <span className="chip-remove">×</span>
                    </button>
                  );
                })}
                {filterTypes.map(type => (
                  <button key={type} className={`tx-active-chip ${getTypeFilterClass(type)}`} onClick={() => toggleType(type)}>
                    <IonIcon icon={getTypeIcon(type)} />
                    {type} <span className="chip-remove">×</span>
                  </button>
                ))}
                {filterTags.map(tag => (
                  <button key={tag} className="tx-active-chip tx-active-chip--tag" onClick={() => toggleTag(tag)}>
                    #{tag} <span className="chip-remove">×</span>
                  </button>
                ))}
                <button className="tx-filter-clear-all" onClick={() => { setFilterCategories([]); setFilterTypes([]); setFilterTags([]); }}>
                  Clear all
                </button>
              </div>
            </div>
          )}
        </div>

        <div className={`transaction-list-container${hasActiveFilters ? ' has-active-filters' : ''}`}>
          <div className="tx-filters-main">
            <div className="tx-filters-header">
              <span className="tx-filter-label">Quick Filters</span>
              <div className="tx-filters-actions">
                <button className="tx-search-open-btn" onClick={() => setIsSearchModalOpen(true)}>
                  <IonIcon icon={searchOutline} /> Search
                </button>
                <button className="tx-filter-open-btn" onClick={() => setIsFilterSheetOpen(true)}>
                  <IonIcon icon={optionsOutline} /> All Filters
                </button>
              </div>
            </div>
            <div className="tx-filter-chips">
              {sortedCategoriesByFreq.slice(0, 2).map(({ cat, emoji }) => (
                <button key={cat} className={`tx-filter-chip${filterCategories.includes(cat) ? ' active' : ''}`} onClick={() => toggleCategory(cat)}>
                  {emoji} {cat}
                </button>
              ))}
              {sortedTagsByFrequency.slice(0, 2).map(tag => (
                <button key={tag} className={`tx-tag-chip${filterTags.includes(tag) ? ' active' : ''}`} onClick={() => toggleTag(tag)}>
                  #{tag}
                </button>
              ))}
            </div>
          </div>

          {Object.entries(groupedTransactions).map(([dateKey, items]) => {
            const dateObj = items[0].date instanceof Date ? items[0].date : new Date(items[0].date);
            const sectionDateKey = toLocalDateKey(dateObj);
            return (
              <div
                key={dateKey}
                className="transaction-group-section"
                data-date-key={sectionDateKey}
                ref={(el) => {
                  if (el) {
                    transactionDateSectionRefs.current.set(sectionDateKey, el);
                  } else {
                    transactionDateSectionRefs.current.delete(sectionDateKey);
                  }
                }}
              >
                <div className="sticky-date-header">{formatTransactionDate(dateObj)}</div>
                {items.map((transaction) => (
                  <IonItemSliding key={transaction.id} className="transaction-sliding-item">
                    <IonItem
                      button
                      onClick={() => handleTransactionClick(transaction)}
                      className="transaction-row-item"
                      lines="none"
                    >
                      <IonLabel>
                        <div className="transaction-item">
                          <span className="emoji">{transaction.emoji}</span>
                          <div className="transaction-details">
                            <span className="title">{transaction.title}</span>
                            <span className="description">{getPlainDescription(transaction.description)}</span>
                          </div>
                        </div>
                      </IonLabel>
                      <div slot="end" className="amount">
                        <span>
                          <span className="amount-sign">{getAmountSign(transaction.isIncome)}</span>
                          <span className="amount-integer">{splitAmount(transaction.amount).integer}</span>
                          <span className="amount-decimal">.{splitAmount(transaction.amount).decimal}</span>
                          <span className="currency-label">{transaction.currency}</span>
                        </span>
                      </div>
                    </IonItem>
                    <IonItemOptions side="end">
                      <IonItemOption
                        color="danger"
                        expandable
                        onClick={(event) => {
                          const slidingItem = event.currentTarget.closest('ion-item-sliding') as HTMLIonItemSlidingElement | null;
                          void handleDeleteTransaction(transaction, slidingItem);
                        }}
                      >
                        <IonIcon slot="icon-only" icon={trashOutline} />
                      </IonItemOption>
                    </IonItemOptions>
                  </IonItemSliding>
                ))}
              </div>
            );
          })}
          {Object.keys(groupedTransactions).length === 0 && (
            <div className="tx-empty-state">No transactions match the selected filters</div>
          )}
        </div>

        {/* ШТОРКА ДЕТАЛЕЙ ТРАНЗАКЦИИ */}
        <IonModal
          isOpen={showTransactionModal}
          onDidDismiss={() => setShowTransactionModal(false)}
          className="transaction-detail-modal"
          mode="ios"
          breakpoints={[0, 0.55, 1]}
          initialBreakpoint={0.55}
        >
          {selectedTransaction && (
            <>
              <div className="transaction-detail-header-container">
                <div className="transaction-detail-topbar">
                  <span className="transaction-detail-topbar-title">Transaction</span>
                  <button
                    className="transaction-detail-edit-btn"
                    type="button"
                    onClick={() => handleEditTransaction(selectedTransaction)}
                  >
                    <IonIcon icon={createOutline} />
                    Edit
                  </button>
                </div>
                <div className="transaction-detail-header">
                  <div className="detail-emoji-wrapper">
                    <span className="detail-emoji">{selectedTransaction.emoji}</span>
                  </div>
                  <div className="detail-header-text">
                    <div className="transaction-detail-title">{selectedTransaction.title}</div>
                    <div className="transaction-detail-subtitle">{selectedTransaction.category}</div>
                  </div>
                </div>
              </div>
              
              <IonContent className="transaction-detail-content">
                <div className="transaction-detail-info">
                  <div className="detail-info-row">
                    <span className="transaction-detail-label">Amount</span>
                    <span className={`detail-amount ${selectedTransaction.isIncome ? 'income' : 'expense'}`}>
                      <span className="amount-sign">{getAmountSign(selectedTransaction.isIncome)}</span>
                      <span className="amount-integer">{splitAmount(selectedTransaction.amount).integer}</span>
                      <span className="amount-decimal">.{splitAmount(selectedTransaction.amount).decimal}</span>
                      <span className="currency-label">{selectedTransaction.currency}</span>
                    </span>
                  </div>
                  <div className="detail-info-row">
                    <span className="transaction-detail-label">Date</span>
                    <span className="transaction-detail-value">{formatDateWithTime(selectedTransaction.date)}</span>
                  </div>
                  <div className="detail-info-row">
                    <span className="transaction-detail-label">Type</span>
                    <IonBadge className={getTypeBadgeClass(selectedTransaction.type)}>{selectedTransaction.type}</IonBadge>
                  </div>
                  <div className="detail-info-row">
                    <span className="transaction-detail-label">Tags</span>
                    <span className="transaction-detail-value">
                      {selectedTransaction.tags && selectedTransaction.tags.length > 0
                        ? selectedTransaction.tags.map((tag: string) => <span className="transaction-tag" key={tag}>#{tag}</span>)
                        : '—'}
                    </span>
                  </div>
                  {selectedTransaction.description.trim() && (
                    <div className="detail-description-section">
                      <div className="transaction-detail-label">Notes</div>
                      <div className="transaction-markdown">
                        <ReactMarkdown remarkPlugins={[remarkGfm]}>{selectedTransaction.description}</ReactMarkdown>
                      </div>
                    </div>
                  )}
                  <button
                    className="transaction-detail-delete-btn"
                    onClick={() => void handleDeleteTransaction(selectedTransaction)}
                  >
                    <IonIcon icon={trashOutline} />
                    Delete transaction
                  </button>
                </div>
              </IonContent>
            </>
          )}
        </IonModal>

        <CreateTransactionModal
          isOpen={isEditTransactionOpen}
          initialTransaction={editingTransaction}
          onClose={() => {
            setIsEditTransactionOpen(false);
            setEditingTransaction(null);
          }}
        />

        {/* ШТОРКА ФИЛЬТРОВ */}
        <IonModal
          isOpen={isFilterSheetOpen}
          onDidDismiss={() => setIsFilterSheetOpen(false)}
          className="filter-sheet-modal"
          mode="ios"
          breakpoints={[0, 0.65, 1]}
          initialBreakpoint={0.65}
        >
          <div className="filter-sheet-header">
            <span className="filter-sheet-title">All Filters</span>
            <button className="filter-sheet-done" onClick={() => setIsFilterSheetOpen(false)}>Done</button>
          </div>
          <IonContent className="filter-sheet-content">
            <div className="filter-sheet-body">
              
              <div className="filter-section">
                <span className="tx-filter-label">Date</span>
                <button className="pick-date-btn" onClick={handlePickDateClick}>
                  Pick a date
                </button>
              </div>

              <div className="filter-section">
                <span className="tx-filter-label">Categories</span>
                <div className="filter-section-chips">
                  {(expandedFilters.category ? sortedCategoriesByFreq : sortedCategoriesByFreq.slice(0, VISIBLE_FILTER_LIMIT)).map(({ cat, emoji }) => (
                    <button key={cat} className={`tx-filter-chip large${filterCategories.includes(cat) ? ' active' : ''}`} onClick={() => toggleCategory(cat)}>
                      {emoji} {cat}
                    </button>
                  ))}
                </div>
                {!expandedFilters.category && sortedCategoriesByFreq.length > VISIBLE_FILTER_LIMIT && (
                  <button className="filter-expand-btn" onClick={() => setExpandedFilters(p => ({ ...p, category: true }))}>
                    Show all {sortedCategoriesByFreq.length} categories
                  </button>
                )}
              </div>

              <div className="filter-section">
                <span className="tx-filter-label">Transaction Type</span>
                <div className="filter-section-chips">
                  {(expandedFilters.type ? sortedTypesByFreq : sortedTypesByFreq.slice(0, VISIBLE_FILTER_LIMIT)).map(type => (
                    <button
                      key={type}
                      className={`tx-filter-chip large ${getTypeFilterClass(type)}${filterTypes.includes(type) ? ' active' : ''}`}
                      onClick={() => toggleType(type)}
                    >
                      <IonIcon icon={getTypeIcon(type)} />
                      {type}
                    </button>
                  ))}
                </div>
                {!expandedFilters.type && sortedTypesByFreq.length > VISIBLE_FILTER_LIMIT && (
                  <button className="filter-expand-btn" onClick={() => setExpandedFilters(p => ({ ...p, type: true }))}>
                    Show all {sortedTypesByFreq.length} types
                  </button>
                )}
              </div>

              {sortedTagsByFrequency.length > 0 && (
                <div className="filter-section">
                  <span className="tx-filter-label">Tags</span>
                  <div className="filter-section-chips">
                    {(expandedFilters.tag ? sortedTagsByFrequency : sortedTagsByFrequency.slice(0, VISIBLE_FILTER_LIMIT)).map(tag => (
                      <button key={tag} className={`tx-tag-chip large${filterTags.includes(tag) ? ' active' : ''}`} onClick={() => toggleTag(tag)}>
                        #{tag}
                      </button>
                    ))}
                  </div>
                  {!expandedFilters.tag && sortedTagsByFrequency.length > VISIBLE_FILTER_LIMIT && (
                    <button className="filter-expand-btn" onClick={() => setExpandedFilters(p => ({ ...p, tag: true }))}>
                      Show all {sortedTagsByFrequency.length} tags
                    </button>
                  )}
                </div>
              )}

            </div>
          </IonContent>
        </IonModal>

        <IonModal
          isOpen={isDatePickerOpen}
          onDidDismiss={() => setIsDatePickerOpen(false)}
          className="date-picker-modal"
          mode="ios"
          breakpoints={[0, 0.75, 1]}
          initialBreakpoint={0.75}
        >
          <div className="date-picker-header">
            <span className="date-picker-title">Pick a date</span>
            <button className="filter-sheet-done" onClick={() => setIsDatePickerOpen(false)}>Close</button>
          </div>
          
          <IonContent className="date-picker-content">
            <div className="date-picker-body">
              <div className="date-picker-month-nav">
                <button
                  className="date-picker-month-btn"
                  onClick={handlePrevMonth}
                  disabled={isPrevMonthDisabled}
                >
                  <IonIcon icon={chevronBackOutline} />
                </button>
                <div className="date-picker-month-title">{monthTitle}</div>
                <button
                  className="date-picker-month-btn"
                  onClick={handleNextMonth}
                  disabled={isNextMonthDisabled}
                >
                  <IonIcon icon={chevronForwardOutline} />
                </button>
              </div>
              <div className="date-picker-weekdays">
                {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => (
                  <span key={day}>{day}</span>
                ))}
              </div>
              <div className="date-picker-grid">
                {calendarCells.map((cell, idx) => (
                  <button
                    key={cell.dateKey ?? `empty-${idx}`}
                    className={`date-picker-day${cell.day ? '' : ' is-empty'}${!cell.hasTransactions && cell.day ? ' is-disabled' : ''}${cell.hasTransactions ? ' has-transactions' : ''}`}
                    onClick={() => {
                      if (cell.dateKey && cell.hasTransactions) {
                        handleDatePick(cell.dateKey);
                      }
                    }}
                    disabled={!cell.hasTransactions && cell.day !== null}
                  >
                    {cell.day ?? ''}
                  </button>
                ))}
              </div>
              <div className="date-picker-hint">Only dates with transactions are highlighted</div>
            </div>
          </IonContent>
        </IonModal>

        <IonModal
          isOpen={isSearchModalOpen}
          onDidDismiss={handleCloseSearchModal}
          className="search-modal"
          mode="ios"
        >
          <div className="search-modal-header">
            <div className="search-input-shell">
              <IonIcon icon={searchOutline} />
              <input
                className="search-input"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search by title or notes"
                autoFocus
              />
            </div>
            <button className="search-cancel-btn" onClick={handleCloseSearchModal}>Cancel</button>
          </div>
          <IonContent className="search-modal-content">
            <div className="search-results-list">
              {normalizedSearchQuery.length > 0 && searchResults.length === 0 && (
                <div className="search-empty-hint">No transactions found</div>
              )}
              {searchResults.map((transaction) => (
                <button
                  key={transaction.id}
                  className="search-result-row"
                  onClick={() => handleSearchResultClick(transaction)}
                >
                  <span className="search-result-emoji">{transaction.emoji}</span>
                  <span className="search-result-main">
                    <span className="search-result-title">{transaction.title}</span>
                    <span className="search-result-meta">{formatDateBeautifully(transaction.date)}</span>
                    <span className="search-result-note">{getPlainDescription(transaction.description)}</span>
                  </span>
                </button>
              ))}
            </div>
          </IonContent>
        </IonModal>
      </IonContent>
    </IonPage>
  );
};

export default Home;