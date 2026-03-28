import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { IonContent, IonIcon, IonModal } from '@ionic/react';
import {
  backspaceOutline,
  calendarOutline,
  chevronBackOutline,
  chevronForwardOutline,
  checkmarkSharp,
  closeOutline,
  documentTextOutline,
  searchOutline,
} from 'ionicons/icons';
import { CurrencyCode, getCategoryEmoji, Transaction, useTransactions } from '../context/TransactionsContext';
import { getRandomAvailableCategoryEmoji } from '../utils/categoryEmoji';
import './CreateTransactionModal.css';

type CreateTransactionModalProps = {
  isOpen: boolean;
  onClose: () => void;
  initialTransaction?: Transaction | null;
};

type TransactionType = 'Expenses' | 'Income';

type PreferredCategory = {
  title: string;
  found: boolean;
};

type PreferredCurrency = {
  code: CurrencyCode;
  found: boolean;
};

type FormState = {
  currency: CurrencyCode;
  amount: string;
  date: Date;
  type: TransactionType;
  category: string;
  title: string;
  note: string;
  tags: string[];
  isTitleEditing: boolean;
  showNoteModal: boolean;
  showDatePicker: boolean;
  showCategoryPicker: boolean;
};

const MAX_INTEGER_DIGITS = 8;
const MAX_DECIMAL_DIGITS = 2;
const MAX_CATEGORY_TITLE_LENGTH = 30;

const splitAmount = (amount: number) => {
  const [integer, decimal] = amount.toFixed(2).split('.');
  return { integer: Number(integer).toLocaleString('ru-RU'), decimal };
};

const formatAmountForDisplay = (amountRaw: string) => {
  if (!amountRaw) {
    return { integer: '0', decimal: '00' };
  }

  if (amountRaw.endsWith('.')) {
    const integerPart = Number(amountRaw.slice(0, -1) || '0').toLocaleString('ru-RU');
    return { integer: integerPart, decimal: '' };
  }

  const amount = Number.parseFloat(amountRaw);
  if (!Number.isFinite(amount)) {
    return { integer: '0', decimal: '00' };
  }

  const { integer, decimal } = splitAmount(amount);
  const hasDot = amountRaw.includes('.');
  if (!hasDot) {
    return { integer, decimal: '' };
  }

  const enteredDecimal = amountRaw.split('.')[1] ?? '';
  return { integer, decimal: enteredDecimal };
};

const formatPillDate = (date: Date): string => {
  const weekday = date.toLocaleString('en-US', { weekday: 'short' });
  const day = date.getDate();
  const month = date.toLocaleString('en-US', { month: 'short' });
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  return `${weekday}, ${day} ${month}\u2003${hours}:${minutes}`;
};

const toLocalDateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;

const formatTimeInputValue = (date: Date) => `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;

const clampDateToNow = (date: Date) => {
  const now = new Date();
  return date.getTime() > now.getTime() ? now : date;
};

const formatAmountInputValue = (amount: number) => amount
  .toFixed(2)
  .replace(/\.00$/, '')
  .replace(/(\.\d*[1-9])0+$/, '$1');

const NUMPAD_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', 'confirm'] as const;

const DEFAULT_CATEGORY_BY_TYPE: Record<TransactionType, string> = {
  Expenses: 'Shopping',
  Income: 'Income',
};

const EMOJI_REGEX = /(\p{Emoji_Presentation}|\p{Extended_Pictographic})/gu;

const getTagsFromDraft = (draft: string) => draft
  .split(',')
  .map((tag) => tag.trim())
  .filter(Boolean);

const mergeTags = (currentTags: string[], nextTags: string[]) => {
  const seen = new Set(currentTags.map((tag) => tag.toLocaleLowerCase()));
  const merged = [...currentTags];

  nextTags.forEach((tag) => {
    const normalized = tag.toLocaleLowerCase();

    if (!seen.has(normalized)) {
      seen.add(normalized);
      merged.push(tag);
    }
  });

  return merged;
};

const buildInitialFormState = (
  currency: CurrencyCode,
  category: string,
  transaction?: Transaction | null,
): FormState => {
  if (transaction) {
    return {
      currency: transaction.currency,
      amount: formatAmountInputValue(transaction.amount),
      date: clampDateToNow(new Date(transaction.date)),
      type: transaction.type === 'Income' ? 'Income' : 'Expenses',
      category: transaction.category,
      title: transaction.title,
      note: transaction.description,
      tags: [...transaction.tags],
      isTitleEditing: false,
      showNoteModal: false,
      showDatePicker: false,
      showCategoryPicker: false,
    };
  }

  return {
    currency,
    amount: '',
    date: new Date(),
    type: 'Expenses',
    category,
    title: '',
    note: '',
    tags: [],
    isTitleEditing: false,
    showNoteModal: false,
    showDatePicker: false,
    showCategoryPicker: false,
  };
};

const CreateTransactionModal: React.FC<CreateTransactionModalProps> = ({ isOpen, onClose, initialTransaction = null }) => {
  const {
    addTransaction,
    addCategory,
    categories,
    currencyOptions,
    selectedCurrency,
    transactions,
    updateTransaction,
  } = useTransactions();

  const [form, setForm] = useState<FormState>(() => buildInitialFormState(selectedCurrency, DEFAULT_CATEGORY_BY_TYPE.Expenses));
  const [categoriesSearchQuery, setCategoriesSearchQuery] = useState('');
  const [isCreateCategoryOpen, setIsCreateCategoryOpen] = useState(false);
  const [newCategoryEmoji, setNewCategoryEmoji] = useState('');
  const [newCategoryTitle, setNewCategoryTitle] = useState('');
  const [categoryCreationError, setCategoryCreationError] = useState('');
  const [tagDraft, setTagDraft] = useState('');
  const [calendarMonth, setCalendarMonth] = useState(() => {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1);
  });
  const titleInputRef = useRef<HTMLTextAreaElement>(null);
  const noteInputRef = useRef<HTMLTextAreaElement>(null);
  const shouldMoveTitleCursorToEndRef = useRef(false);

  const availableCurrencies = useMemo(() => currencyOptions, [currencyOptions]);

  const preferredCurrency = useMemo<PreferredCurrency>(() => {
    const stats = new Map<CurrencyCode, { count: number; latestTimestamp: number }>();

    transactions.forEach((transaction) => {
      if (!transaction.currency) {
        return;
      }

      const current = stats.get(transaction.currency) ?? { count: 0, latestTimestamp: 0 };
      const timestamp = new Date(transaction.date).getTime();

      stats.set(transaction.currency, {
        count: current.count + 1,
        latestTimestamp: Math.max(current.latestTimestamp, timestamp),
      });
    });

    if (stats.size === 0) {
      return { code: selectedCurrency, found: false };
    }

    const bestCurrency = Array.from(stats.entries()).sort((left, right) => {
      const [, leftStats] = left;
      const [, rightStats] = right;

      if (rightStats.count !== leftStats.count) {
        return rightStats.count - leftStats.count;
      }

      if (rightStats.latestTimestamp !== leftStats.latestTimestamp) {
        return rightStats.latestTimestamp - leftStats.latestTimestamp;
      }

      return left[0].localeCompare(right[0]);
    })[0]?.[0];

    return {
      code: bestCurrency ?? selectedCurrency,
      found: Boolean(bestCurrency),
    };
  }, [selectedCurrency, transactions]);

  const preferredCategoryByType = useMemo<Record<TransactionType, PreferredCategory>>(() => {
    const categoryOrder = new Map(categories.map((category, index) => [category.title, index]));

    const resolvePreferredCategory = (type: TransactionType): PreferredCategory => {
      const stats = new Map<string, { count: number; latestTimestamp: number }>();

      transactions.forEach((transaction) => {
        if (transaction.type !== type || !categoryOrder.has(transaction.category)) {
          return;
        }

        const current = stats.get(transaction.category) ?? { count: 0, latestTimestamp: 0 };
        const timestamp = new Date(transaction.date).getTime();

        stats.set(transaction.category, {
          count: current.count + 1,
          latestTimestamp: Math.max(current.latestTimestamp, timestamp),
        });
      });

      if (stats.size === 0) {
        return { title: DEFAULT_CATEGORY_BY_TYPE[type], found: false };
      }

      const bestCategory = Array.from(stats.entries()).sort((left, right) => {
        const [, leftStats] = left;
        const [, rightStats] = right;

        if (rightStats.count !== leftStats.count) {
          return rightStats.count - leftStats.count;
        }

        if (rightStats.latestTimestamp !== leftStats.latestTimestamp) {
          return rightStats.latestTimestamp - leftStats.latestTimestamp;
        }

        return (categoryOrder.get(left[0]) ?? Number.MAX_SAFE_INTEGER) - (categoryOrder.get(right[0]) ?? Number.MAX_SAFE_INTEGER);
      })[0]?.[0];

      return {
        title: bestCategory ?? DEFAULT_CATEGORY_BY_TYPE[type],
        found: Boolean(bestCategory),
      };
    };

    return {
      Expenses: resolvePreferredCategory('Expenses'),
      Income: resolvePreferredCategory('Income'),
    };
  }, [categories, transactions]);

  const currentPreferredCategory = preferredCategoryByType[form.type];
  const currentPreferredCategoryLabel = form.type === 'Expenses'
    ? 'Often used for expenses'
    : 'Often used for income';

  const fallbackTitle = useMemo(() => `My ${form.category}`, [form.category]);

  const filteredCategories = useMemo(() => {
    const query = categoriesSearchQuery.trim().toLowerCase();
    const matchedCategories = !query
      ? categories
      : categories.filter((category) => {
          const searchable = `${category.emoji} ${category.title}`.toLowerCase();
          return searchable.includes(query);
        });

    return matchedCategories.sort((left, right) => {
      const leftIsPreferred = currentPreferredCategory.found && left.title === currentPreferredCategory.title;
      const rightIsPreferred = currentPreferredCategory.found && right.title === currentPreferredCategory.title;

      if (leftIsPreferred === rightIsPreferred) {
        return 0;
      }

      return leftIsPreferred ? -1 : 1;
    });
  }, [categories, categoriesSearchQuery, currentPreferredCategory]);

  useEffect(() => {
    if (isOpen) {
      const now = new Date();

      setForm(buildInitialFormState(preferredCurrency.code, preferredCategoryByType.Expenses.title, initialTransaction));
      setCategoriesSearchQuery('');
      setIsCreateCategoryOpen(false);
      setNewCategoryEmoji('');
      setNewCategoryTitle('');
      setCategoryCreationError('');
      setTagDraft('');
      const baseDate = initialTransaction ? new Date(initialTransaction.date) : now;
      setCalendarMonth(new Date(baseDate.getFullYear(), baseDate.getMonth(), 1));
    }
  }, [initialTransaction, isOpen, preferredCategoryByType, preferredCurrency.code]);

  useEffect(() => {
    if (form.isTitleEditing) {
      titleInputRef.current?.focus({ preventScroll: true });
      if (shouldMoveTitleCursorToEndRef.current && titleInputRef.current) {
        const textLength = titleInputRef.current.value.length;
        titleInputRef.current.setSelectionRange(textLength, textLength);
        shouldMoveTitleCursorToEndRef.current = false;
      }
    }
  }, [form.isTitleEditing]);

  useEffect(() => {
    if (form.showNoteModal) {
      noteInputRef.current?.focus({ preventScroll: true });
    }
  }, [form.showNoteModal]);

  const handleActivateTitleEditing = useCallback(() => {
    const hasExistingTitle = form.title.trim().length > 0;
    shouldMoveTitleCursorToEndRef.current = hasExistingTitle;

    setForm((prev) => ({
      ...prev,
      isTitleEditing: true,
      title: hasExistingTitle ? prev.title : '',
    }));
  }, [form.title]);

  const handleDismiss = () => {
    setForm(buildInitialFormState(preferredCurrency.code, preferredCategoryByType.Expenses.title));
    setCategoriesSearchQuery('');
    setIsCreateCategoryOpen(false);
    setNewCategoryEmoji('');
    setNewCategoryTitle('');
    setCategoryCreationError('');
    setTagDraft('');
    onClose();
  };

  const handleCategoryModalDismiss = () => {
    setForm((prev) => ({ ...prev, showCategoryPicker: false }));
    setCategoriesSearchQuery('');
    setIsCreateCategoryOpen(false);
    setNewCategoryEmoji('');
    setNewCategoryTitle('');
    setCategoryCreationError('');
  };

  const handleDateModalDismiss = useCallback(() => {
    setForm((prev) => ({ ...prev, showDatePicker: false }));
  }, []);

  const handleNoteModalDismiss = useCallback(() => {
    const draftTags = getTagsFromDraft(tagDraft);

    setForm((prev) => ({
      ...prev,
      note: prev.note.trim().length === 0 ? '' : prev.note,
      tags: draftTags.length > 0 ? mergeTags(prev.tags, draftTags) : prev.tags,
      showNoteModal: false,
    }));
    setTagDraft('');
  }, [tagDraft]);

  const handleOpenNoteModal = useCallback(() => {
    setForm((prev) => ({
      ...prev,
      isTitleEditing: false,
      showNoteModal: true,
    }));
  }, []);

  const handleOpenDatePicker = useCallback(() => {
    setCalendarMonth(new Date(form.date.getFullYear(), form.date.getMonth(), 1));
    setForm((prev) => ({
      ...prev,
      isTitleEditing: false,
      showDatePicker: true,
    }));
  }, [form.date]);

  const handleAddTagDraft = useCallback(() => {
    const draftTags = getTagsFromDraft(tagDraft);

    if (draftTags.length === 0) {
      setTagDraft('');
      return;
    }

    setForm((prev) => ({
      ...prev,
      tags: mergeTags(prev.tags, draftTags),
    }));
    setTagDraft('');
  }, [tagDraft]);

  const handleRemoveTag = useCallback((tagToRemove: string) => {
    setForm((prev) => ({
      ...prev,
      tags: prev.tags.filter((tag) => tag !== tagToRemove),
    }));
  }, []);

  const handleCreateCategoryModalDismiss = () => {
    setIsCreateCategoryOpen(false);
    setNewCategoryEmoji('');
    setNewCategoryTitle('');
    setCategoryCreationError('');
  };

  const handleOpenCreateCategoryModal = () => {
    setNewCategoryEmoji(getRandomAvailableCategoryEmoji(categories.map((category) => category.emoji)));
    setNewCategoryTitle('');
    setCategoryCreationError('');
    setIsCreateCategoryOpen(true);
  };

  const handleEmojiChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const emojis = event.target.value.match(EMOJI_REGEX) || [];
    setNewCategoryEmoji(emojis.join('').slice(0, 2));
    setCategoryCreationError('');
  };

  const handleCreateCategory = () => {
    setCategoryCreationError('');

    if (!newCategoryEmoji.trim()) {
      setCategoryCreationError('Emoji is required');
      return;
    }

    if (newCategoryEmoji === '❓') {
      setCategoryCreationError('This emoji is reserved for unknown transactions');
      return;
    }

    if (!newCategoryTitle.trim()) {
      setCategoryCreationError('Category title is required');
      return;
    }

    if (newCategoryTitle.trim().length > MAX_CATEGORY_TITLE_LENGTH) {
      setCategoryCreationError(`Category title must be ${MAX_CATEGORY_TITLE_LENGTH} characters or less`);
      return;
    }

    if (categories.some((category) => category.emoji === newCategoryEmoji.trim())) {
      setCategoryCreationError('A category with this emoji already exists');
      return;
    }

    const createdTitle = newCategoryTitle.trim();
    addCategory(newCategoryEmoji.trim(), createdTitle);
    setForm((prev) => ({
      ...prev,
      category: createdTitle,
      showCategoryPicker: false,
    }));
    setCategoriesSearchQuery('');
    handleCreateCategoryModalDismiss();
  };

  const handleKeyPress = useCallback((key: string) => {
    setForm((prev) => {
      let next = prev.amount;

      if (key === 'backspace') {
        next = next.slice(0, -1);
      } else if (key === '.') {
        if (!next.includes('.')) {
          next = (next || '0') + '.';
        }
      } else {
        const [intPart, decPart] = next.split('.');
        if (decPart !== undefined && decPart.length >= MAX_DECIMAL_DIGITS) return prev;
        if (decPart === undefined && (intPart || '').replace(/^0/, '').length >= MAX_INTEGER_DIGITS) return prev;
        next = next === '0' ? key : next + key;
      }

      return { ...prev, amount: next };
    });
  }, []);

  const amountNum = Number.parseFloat(form.amount);
  const hasValidAmount = Number.isFinite(amountNum) && amountNum > 0;

  const handleConfirm = () => {
    if (!hasValidAmount) return;

    const safeDate = clampDateToNow(new Date(form.date));
    const payload = {
      emoji: getCategoryEmoji(form.category, categories),
      category: form.category || 'Uncategorized',
      title: form.title.trim() || fallbackTitle,
      description: form.note.trim(),
      amount: amountNum,
      currency: form.currency,
      date: safeDate,
      type: form.type,
      isIncome: form.type === 'Income',
      tags: form.tags,
    };

    if (initialTransaction) {
      updateTransaction(initialTransaction.id, payload);
    } else {
      addTransaction(payload);
    }

    handleDismiss();
  };

  const amountFontSize = useMemo(() => {
    const len = (form.amount || '0').replace('.', '').length;
    if (len <= 4) return 64;
    if (len <= 6) return 52;
    if (len <= 8) return 42;
    return 34;
  }, [form.amount]);

  const secondaryAmountFontSize = useMemo(() => Math.round(amountFontSize * 0.52), [amountFontSize]);
  const titleFontSize = useMemo(() => {
    const content = (form.title || fallbackTitle).trim();
    const lineBreaks = (form.title.match(/\n/g) || []).length;
    const length = content.length;

    if (lineBreaks >= 2 || length > 26) return 28;
    if (lineBreaks >= 1 || length > 20) return 34;
    if (length > 14) return 42;
    return 52;
  }, [fallbackTitle, form.title]);

  const displayAmount = useMemo(() => formatAmountForDisplay(form.amount), [form.amount]);
  const hasNote = form.note.trim().length > 0;
  const hasNoteDetails = hasNote || form.tags.length > 0;
  const noteTitlePreview = form.title.trim() || fallbackTitle;
  const now = new Date();
  const currentDateKey = useMemo(() => toLocalDateKey(now), [now]);
  const selectedDateKey = useMemo(() => toLocalDateKey(form.date), [form.date]);
  const timeInputValue = useMemo(() => formatTimeInputValue(form.date), [form.date]);
  const maxTimeValue = selectedDateKey === currentDateKey ? formatTimeInputValue(now) : undefined;
  const monthTitle = useMemo(
    () => calendarMonth.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }),
    [calendarMonth],
  );
  const isNextMonthDisabled = useMemo(
    () => calendarMonth.getFullYear() === now.getFullYear() && calendarMonth.getMonth() === now.getMonth(),
    [calendarMonth, now],
  );

  const calendarCells = useMemo(() => {
    const year = calendarMonth.getFullYear();
    const month = calendarMonth.getMonth();
    const firstDay = new Date(year, month, 1);
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const firstWeekday = (firstDay.getDay() + 6) % 7;
    const cells: Array<{ dateKey: string | null; day: number | null; isSelected: boolean; isFuture: boolean }> = [];

    for (let index = 0; index < firstWeekday; index += 1) {
      cells.push({ dateKey: null, day: null, isSelected: false, isFuture: false });
    }

    for (let day = 1; day <= daysInMonth; day += 1) {
      const dateKey = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      cells.push({
        dateKey,
        day,
        isSelected: dateKey === selectedDateKey,
        isFuture: dateKey > currentDateKey,
      });
    }

    const trailing = (7 - (cells.length % 7)) % 7;
    for (let index = 0; index < trailing; index += 1) {
      cells.push({ dateKey: null, day: null, isSelected: false, isFuture: false });
    }

    return cells;
  }, [calendarMonth, currentDateKey, selectedDateKey]);

  const selectedCategoryEmoji = useMemo(
    () => getCategoryEmoji(form.category, categories),
    [form.category, categories],
  );

  return (
    <IonModal
      isOpen={isOpen}
      onDidDismiss={handleDismiss}
      className="create-transaction-modal"
      mode="ios"
    >
      <div className="create-tx-wrapper">
        {/* Header */}
        <div className="create-tx-header">
          <button className="create-tx-icon-btn" type="button" onClick={handleDismiss}>
            <IonIcon icon={closeOutline} />
          </button>
          <div className="create-tx-type-toggle">
            {(['Expenses', 'Income'] as TransactionType[]).map((t) => (
              <button
                key={t}
                type="button"
                className={`create-tx-type-btn${form.type === t ? ' is-active' : ''}`}
                onClick={() => setForm((p) => ({
                  ...p,
                  type: t,
                  category: preferredCategoryByType[t].title,
                }))}
              >
                {t === 'Expenses' ? 'Expense' : 'Income'}
              </button>
            ))}
          </div>
          <button
            className={`create-tx-icon-btn create-tx-save-btn${hasValidAmount ? '' : ' is-disabled'}`}
            type="button"
            onClick={handleConfirm}
            disabled={!hasValidAmount}
            aria-label="Save transaction"
          >
            <IonIcon icon={checkmarkSharp} />
          </button>
        </div>

        {/* Amount Area */}
        <div className="create-tx-amount-area">
          <div className="create-tx-title-row">
            <div
              className={`create-tx-title-display${form.title.trim() ? '' : ' is-empty'}`}
              style={{ fontSize: titleFontSize }}
              onClick={() => {
                if (!form.isTitleEditing) {
                  handleActivateTitleEditing();
                }
              }}
              role="button"
              tabIndex={0}
              onKeyDown={(event) => {
                if (!form.isTitleEditing && (event.key === 'Enter' || event.key === ' ')) {
                  event.preventDefault();
                  handleActivateTitleEditing();
                }
              }}
            >
              {!form.isTitleEditing && !form.title.trim() && (
                <span className="create-tx-title-placeholder-metric" aria-hidden="true">
                  {fallbackTitle}
                </span>
              )}
              <textarea
                ref={titleInputRef}
                className={`create-tx-title-input${form.isTitleEditing ? ' is-editing' : ''}${form.title.trim() ? ' has-value' : ''}`}
                style={{ fontSize: titleFontSize }}
                value={form.title}
                placeholder={form.isTitleEditing ? '' : fallbackTitle}
                readOnly={!form.isTitleEditing}
                rows={2}
                maxLength={60}
                onChange={(event) => setForm((prev) => ({ ...prev, title: event.target.value }))}
                onBlur={() => setForm((prev) => ({
                  ...prev,
                  title: prev.title.trim().length === 0 ? '' : prev.title,
                  isTitleEditing: false,
                }))}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && !(event.metaKey || event.ctrlKey || event.shiftKey)) {
                    event.preventDefault();
                    handleOpenNoteModal();
                    return;
                  }

                  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
                    event.currentTarget.blur();
                  }
                }}
              />
            </div>
          </div>

          <div className="create-tx-amount-row">
            <span className="create-tx-amount-spacer" aria-hidden="true" />
            <div className="create-tx-amount-main">
              <span className="create-tx-amount-value" style={{ fontSize: amountFontSize }}>
                <span className="create-tx-amount-integer">{displayAmount.integer}</span>
                {form.amount.includes('.') && (
                  <span className="create-tx-amount-decimal">.{displayAmount.decimal}</span>
                )}
              </span>
              <label className="create-tx-currency-picker" style={{ fontSize: secondaryAmountFontSize }}>
                <span className="create-tx-currency-text">{form.currency}</span>
                <select
                  className="create-tx-currency-select"
                  value={form.currency}
                  onChange={(e) => setForm((p) => ({ ...p, currency: e.target.value as CurrencyCode }))}
                >
                  {availableCurrencies.map((currency) => (
                    <option key={currency.code} value={currency.code}>
                      {currency.label}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <button className="create-tx-backspace" type="button" onClick={() => handleKeyPress('backspace')}>
              <IonIcon icon={backspaceOutline} />
            </button>
          </div>

          <div className="create-tx-meta-row">
            <button
              className="create-tx-note-toggle has-value"
              type="button"
              onClick={() => setForm((p) => ({ ...p, showCategoryPicker: true }))}
            >
              <span className="create-tx-note-toggle-emoji">{selectedCategoryEmoji}</span>
              <span className="create-tx-note-toggle-text">{form.category}</span>
            </button>
            {hasNoteDetails && (
              <button
                className="create-tx-note-indicator"
                type="button"
                onClick={handleOpenNoteModal}
                aria-label="Open notes and tags"
              >
                <IonIcon icon={documentTextOutline} />
              </button>
            )}
          </div>
        </div>

        {/* Bottom Section */}
        <div className="create-tx-bottom">
          <div className="create-tx-controls-row">
            <button
              className="create-tx-pill is-interactive"
              type="button"
              onClick={handleOpenDatePicker}
            >
              <IonIcon icon={calendarOutline} />
              <span>{formatPillDate(form.date)}</span>
            </button>
          </div>

          <div className="create-tx-numpad">
            {NUMPAD_KEYS.map((key) => (
              <button
                key={key}
                type="button"
                className={`create-tx-numpad-btn${key === 'confirm' ? ' is-confirm' : ''}${
                  key === 'confirm' && !hasValidAmount ? ' is-disabled' : ''
                }`}
                onClick={() => (key === 'confirm' ? handleConfirm() : handleKeyPress(key))}
              >
                {key === 'confirm' ? <IonIcon icon={checkmarkSharp} /> : key}
              </button>
            ))}
          </div>
        </div>

        <IonModal
          isOpen={form.showDatePicker}
          onDidDismiss={handleDateModalDismiss}
          className="create-tx-date-picker-modal"
          mode="ios"
          breakpoints={[0, 0.75, 1]}
          initialBreakpoint={0.75}
        >
          <div className="create-tx-date-picker-header">
            <span className="create-tx-date-picker-title">Date &amp; Time</span>
            <button className="create-tx-date-picker-close" type="button" onClick={handleDateModalDismiss}>
              Done
            </button>
          </div>

          <IonContent className="create-tx-date-picker-content">
            <div className="create-tx-date-picker-body">
              <div className="create-tx-date-picker-month-nav">
                <button
                  className="create-tx-date-picker-month-btn"
                  type="button"
                  onClick={() => setCalendarMonth((prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1))}
                >
                  <IonIcon icon={chevronBackOutline} />
                </button>
                <div className="create-tx-date-picker-month-title">{monthTitle}</div>
                <button
                  className="create-tx-date-picker-month-btn"
                  type="button"
                  onClick={() => setCalendarMonth((prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1))}
                  disabled={isNextMonthDisabled}
                >
                  <IonIcon icon={chevronForwardOutline} />
                </button>
              </div>

              <div className="create-tx-date-picker-weekdays">
                {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => (
                  <span key={day}>{day}</span>
                ))}
              </div>

              <div className="create-tx-date-picker-grid">
                {calendarCells.map((cell, index) => (
                  <button
                    key={cell.dateKey ?? `empty-${index}`}
                    className={`create-tx-date-picker-day${cell.day ? '' : ' is-empty'}${cell.isSelected ? ' is-selected' : ''}${cell.isFuture ? ' is-disabled' : ''}`}
                    type="button"
                    onClick={() => {
                      if (!cell.dateKey || cell.isFuture) {
                        return;
                      }

                      const [year, month, day] = cell.dateKey.split('-').map(Number);
                      setForm((prev) => {
                        const nextDate = clampDateToNow(new Date(year, month - 1, day, prev.date.getHours(), prev.date.getMinutes(), 0, 0));

                        return {
                          ...prev,
                          date: nextDate,
                        };
                      });
                    }}
                    disabled={!cell.dateKey || cell.isFuture}
                  >
                    {cell.day ?? ''}
                  </button>
                ))}
              </div>

              <div className="create-tx-date-picker-time-row">
                <div className="create-tx-date-picker-time-block">
                  <div className="create-tx-date-picker-time-topline">
                    <span className="create-tx-date-picker-time-label">Time</span>
                    <button
                      className="create-tx-date-picker-now-link"
                      type="button"
                      onClick={() => {
                        const nextNow = new Date();
                        setCalendarMonth(new Date(nextNow.getFullYear(), nextNow.getMonth(), 1));
                        setForm((prev) => ({
                          ...prev,
                          date: nextNow,
                        }));
                      }}
                    >
                      Now
                    </button>
                  </div>
                  <input
                    className="create-tx-date-picker-time-input"
                    type="time"
                    value={timeInputValue}
                    max={maxTimeValue}
                    onChange={(event) => {
                      const [hours, minutes] = event.target.value.split(':').map(Number);

                      if (Number.isNaN(hours) || Number.isNaN(minutes)) {
                        return;
                      }

                      setForm((prev) => {
                        const nextDate = new Date(prev.date);
                        nextDate.setHours(hours, minutes, 0, 0);

                        return {
                          ...prev,
                          date: clampDateToNow(nextDate),
                        };
                      });
                    }}
                    onBlur={() => {
                      setForm((prev) => ({
                        ...prev,
                        date: clampDateToNow(new Date(prev.date)),
                      }));
                    }}
                  />
                </div>
              </div>
            </div>
          </IonContent>
        </IonModal>

        <IonModal
          isOpen={form.showCategoryPicker}
          onDidDismiss={handleCategoryModalDismiss}
          className="create-tx-categories-modal"
          mode="ios"
        >
          <div className="create-tx-categories-search-header">
            <button
              className="create-tx-categories-create"
              type="button"
              onClick={handleOpenCreateCategoryModal}
            >
              Create
            </button>
            <div className="create-tx-categories-search-shell">
              <IonIcon icon={searchOutline} />
              <input
                className="create-tx-categories-search-input"
                value={categoriesSearchQuery}
                onChange={(e) => setCategoriesSearchQuery(e.target.value)}
                placeholder="Search categories"
                autoFocus
              />
            </div>
            <button
              className="create-tx-categories-close"
              type="button"
              onClick={handleCategoryModalDismiss}
            >
              Close
            </button>
          </div>
          <IonContent className="create-tx-categories-content">
            <div className="create-tx-categories-body">
              {filteredCategories.length > 0 ? (
                <div className="create-tx-categories-list">
                  {filteredCategories.map((category) => (
                    <button
                      key={category.title}
                      type="button"
                      className="create-tx-category-row"
                      onClick={() => {
                        setForm((prev) => ({
                          ...prev,
                          category: category.title,
                          showCategoryPicker: false,
                        }));
                        setCategoriesSearchQuery('');
                      }}
                    >
                      <span className="create-tx-category-row-emoji">{category.emoji}</span>
                      <span className="create-tx-category-row-main">
                        <span className="create-tx-category-row-title">{category.title}</span>
                        {currentPreferredCategory.found && currentPreferredCategory.title === category.title && (
                          <span className="create-tx-category-row-subtitle">{currentPreferredCategoryLabel}</span>
                        )}
                      </span>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="create-tx-categories-empty">No categories found</div>
              )}
            </div>
          </IonContent>
        </IonModal>

        <IonModal
          isOpen={form.showNoteModal}
          onDidDismiss={handleNoteModalDismiss}
          className="create-tx-note-modal"
          mode="ios"
        >
          <div className="create-tx-note-modal-header">
            <span className="create-tx-note-modal-title">Notes</span>
            <button
              className="create-tx-note-modal-close"
              type="button"
              onClick={handleNoteModalDismiss}
            >
              Done
            </button>
          </div>
          <IonContent className="create-tx-note-modal-content">
            <div className="create-tx-note-modal-body">
              <div className="create-tx-note-title-preview">{noteTitlePreview}</div>
              <textarea
                ref={noteInputRef}
                className="create-tx-note-textarea"
                value={form.note}
                onChange={(event) => setForm((prev) => ({ ...prev, note: event.target.value }))}
                placeholder="Write a note"
              />
              <div className="create-tx-note-tags-row">
                {form.tags.length > 0 && (
                  <div className="create-tx-note-tags-list">
                    {form.tags.map((tag) => (
                      <span key={tag} className="create-tx-note-tag-chip">
                        <span>{tag}</span>
                        <button
                          className="create-tx-note-tag-remove"
                          type="button"
                          onClick={() => handleRemoveTag(tag)}
                          aria-label={`Remove ${tag} tag`}
                        >
                          ×
                        </button>
                      </span>
                    ))}
                  </div>
                )}
                <input
                  className="create-tx-note-tags-input"
                  type="text"
                  value={tagDraft}
                  onChange={(event) => setTagDraft(event.target.value)}
                  onBlur={handleAddTagDraft}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ',') {
                      event.preventDefault();
                      handleAddTagDraft();
                    }
                  }}
                  placeholder={form.tags.length > 0 ? 'Add tag' : 'Add tags'}
                />
              </div>
            </div>
          </IonContent>
        </IonModal>

        <IonModal
          isOpen={isCreateCategoryOpen}
          onDidDismiss={handleCreateCategoryModalDismiss}
          className="create-tx-create-category-modal"
          mode="ios"
          breakpoints={[0, 0.45, 1]}
          initialBreakpoint={0.45}
        >
          <IonContent className="create-tx-create-category-content">
            <div className="create-tx-create-category-body">
              <input
                type="text"
                className="create-tx-create-category-emoji-input"
                value={newCategoryEmoji}
                onChange={handleEmojiChange}
                onFocus={(event) => event.target.select()}
                onClick={(event) => event.currentTarget.select()}
                placeholder="🙂"
                maxLength={2}
                autoFocus
              />

              {categoryCreationError && (
                <div className="create-tx-create-category-error">{categoryCreationError}</div>
              )}

              <div className="create-tx-create-category-input-row">
                <input
                  type="text"
                  className="create-tx-create-category-title-input"
                  value={newCategoryTitle}
                  maxLength={MAX_CATEGORY_TITLE_LENGTH}
                  onChange={(event) => {
                    setNewCategoryTitle(event.target.value);
                    setCategoryCreationError('');
                  }}
                  placeholder="Category Name"
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      handleCreateCategory();
                    }
                  }}
                />
                <button
                  className="create-tx-create-category-add-btn"
                  type="button"
                  onClick={handleCreateCategory}
                  disabled={!newCategoryEmoji.trim() || !newCategoryTitle.trim()}
                >
                  +
                </button>
              </div>
            </div>
          </IonContent>
        </IonModal>
      </div>
    </IonModal>
  );
};

export default CreateTransactionModal;