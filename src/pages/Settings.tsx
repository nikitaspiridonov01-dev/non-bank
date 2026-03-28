import React, { useMemo, useRef, useState } from 'react';
import { IonContent, IonPage, IonIcon, IonModal } from '@ionic/react';
import { cloudUploadOutline, downloadOutline, searchOutline } from 'ionicons/icons';
import { useTransactions, Transaction, CurrencyCode, Category, validateAndNormalizeTransaction } from '../context/TransactionsContext';
import { getRandomAvailableCategoryEmoji } from '../utils/categoryEmoji';
import './Settings.css';

const formatRateForUi = (value: number) => {
  if (value >= 1) {
    return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(value);
  }

  return new Intl.NumberFormat('en-US', { minimumFractionDigits: 4, maximumFractionDigits: 4 }).format(value);
};

const MAX_CATEGORY_TITLE_LENGTH = 30;

const getUsdRate = (rates: Record<CurrencyCode, number>, currency: CurrencyCode) => rates[currency] ?? 1;

const emojiToCategory = (emoji: string) => {
  switch (emoji) {
    case '🍔': case '☕': case '🥐': return 'Food';
    case '⛽': case '🚕': return 'Transport';
    case '🎬': case '🎮': return 'Entertainment';
    case '📚': case '🛍️': return 'Shopping';
    case '✈️': case '🏨': return 'Travel';
    case '💰': return 'Income';
    case '💻': return 'Work';
    default: return 'Other';
  }
};

const Settings: React.FC = () => {
  const {
    transactions,
    setTransactions,
    selectedCurrency,
    setSelectedCurrency,
    usdRates,
    currencyOptions,
    categories,
    addCategory,
  } = useTransactions();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [isEnabledCurrenciesOpen, setIsEnabledCurrenciesOpen] = useState(false);
  const [isCategoriesOpen, setIsCategoriesOpen] = useState(false);
  const [isCreateCategoryOpen, setIsCreateCategoryOpen] = useState(false);
  const [currencySearchQuery, setCurrencySearchQuery] = useState('');
  const [categoriesSearchQuery, setCategoriesSearchQuery] = useState('');
  const [newCategoryEmoji, setNewCategoryEmoji] = useState('');
  const [newCategoryTitle, setNewCategoryTitle] = useState('');
  const [categoryCreationError, setCategoryCreationError] = useState('');

  const filteredCurrencyOptions = useMemo(() => {
    const q = currencySearchQuery.trim().toLowerCase();
    if (!q) {
      return currencyOptions;
    }

    return currencyOptions.filter((option) => {
      const searchable = `${option.code} ${option.label} ${option.name}`.toLowerCase();
      return searchable.includes(q);
    });
  }, [currencyOptions, currencySearchQuery]);

  const filteredCategories = useMemo(() => {
    const q = categoriesSearchQuery.trim().toLowerCase();
    if (!q) {
      return categories;
    }

    return categories.filter((category) => {
      const searchable = `${category.emoji} ${category.title}`.toLowerCase();
      return searchable.includes(q);
    });
  }, [categories, categoriesSearchQuery]);

  const getCurrencySubtitle = (currency: CurrencyCode) => {
    if (currency === selectedCurrency) {
      return 'base currency';
    }

    const rate = getUsdRate(usdRates, currency) / getUsdRate(usdRates, selectedCurrency);
    if (rate < 1 && rate > 0) {
      const inverted = 1 / rate;
      return `1 ${currency} ≈ ${formatRateForUi(inverted)} ${selectedCurrency}`;
    }

    return `1 ${selectedCurrency} ≈ ${formatRateForUi(rate)} ${currency}`;
  };

  const handleEmojiChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const value = e.target.value;
    // Only allow emoji characters using a comprehensive regex
    // This regex matches a wide variety of emoji including:
    // - Emoticons (☺️, ☹️, etc.)  
    // - Symbols and pictographs (❤️, ⭐, etc.)
    // - Variation selectors
    // - Skin tone modifiers
    // - Zero-width joiners
    const emojiRegex = /(\p{Emoji_Presentation}|\p{Extended_Pictographic})/gu;
    const emojis = value.match(emojiRegex) || [];
    
    // Only keep the first emoji (or allow multiple, but limit to max 2 characters)
    const filtered = emojis.join('').slice(0, 2);
    setNewCategoryEmoji(filtered);
    setCategoryCreationError('');
  };

  const handleCreateCategory = () => {
    setCategoryCreationError('');

    // Validate emoji
    if (!newCategoryEmoji.trim()) {
      setCategoryCreationError('Emoji is required');
      return;
    }

    if (newCategoryEmoji === '❓') {
      setCategoryCreationError('This emoji is reserved for unknown transactions');
      return;
    }

    // Validate title
    if (!newCategoryTitle.trim()) {
      setCategoryCreationError('Category title is required');
      return;
    }

    if (newCategoryTitle.trim().length > MAX_CATEGORY_TITLE_LENGTH) {
      setCategoryCreationError(`Category title must be ${MAX_CATEGORY_TITLE_LENGTH} characters or less`);
      return;
    }

    // Check if category emoji already exists
    if (categories.some((c) => c.emoji === newCategoryEmoji.trim())) {
      setCategoryCreationError('A category with this emoji already exists');
      return;
    }

    // Add the category
    addCategory(newCategoryEmoji.trim(), newCategoryTitle.trim());

    // Reset form and close modal
    setNewCategoryEmoji('');
    setNewCategoryTitle('');
    setCategoryCreationError('');
    setIsCreateCategoryOpen(false);
  };

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

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (event) => {
      try {
        const json = JSON.parse(event.target?.result as string);
        if (Array.isArray(json)) {
          const currentMaxId = transactions.length > 0 ? Math.max(...transactions.map((t) => t.id)) : 0;
          const parsed: Transaction[] = json.map((item, idx) => {
            const parsedCurrency = typeof item.currency === 'string' ? item.currency.toUpperCase() : 'USD';

            const tx: Transaction = {
              ...item,
              id: currentMaxId + idx + 1,
              date: new Date(item.date),
              currency: usdRates[parsedCurrency] ? parsedCurrency : 'USD',
              category: typeof item.category === 'string' ? item.category : Array.isArray(item.category) && item.category.length > 0 ? item.category[0] : emojiToCategory(item.emoji),
              tags: Array.isArray(item.tags) ? item.tags : [],
            };

            return validateAndNormalizeTransaction(tx, categories);
          });
          setTransactions((prev) => [...prev, ...parsed].sort((a, b) => b.date.getTime() - a.date.getTime()));
        }
      } catch (err) {
        alert('Invalid JSON file');
      }
    };
    reader.readAsText(file);
    e.target.value = '';
  };

  const handleImportClick = () => fileInputRef.current?.click();

  const handleExportClick = () => {
    const exportData = transactions.map(({ id, date, ...rest }) => ({
      ...rest,
      date: (date instanceof Date ? date : new Date(date)).toISOString().slice(0, 10),
    }));
    const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'transactions.json';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <IonPage>
      <IonContent fullscreen>
        <div className="settings-container">
          <h1 className="settings-title">Settings</h1>
          <div className="settings-section">
            <div className="settings-group">
              <button className="settings-row" onClick={handleExportClick}>
                <div className="settings-row-icon-wrap">
                  <IonIcon icon={downloadOutline} />
                </div>
                <span className="settings-row-label">Export</span>
                <span className="settings-row-arrow">›</span>
              </button>
              <button className="settings-row" onClick={handleImportClick}>
                <div className="settings-row-icon-wrap">
                  <IonIcon icon={cloudUploadOutline} />
                </div>
                <span className="settings-row-label">Import</span>
                <span className="settings-row-arrow">›</span>
              </button>
              <button className="settings-row" onClick={() => setIsEnabledCurrenciesOpen(true)}>
                <div className="settings-row-icon-wrap settings-row-icon-wrap--currency">¤
                </div>
                <span className="settings-row-label">Enabled currencies</span>
                <span className="settings-row-value">{currencyOptions.length}</span>
                <span className="settings-row-arrow">›</span>
              </button>
              <button className="settings-row" onClick={() => setIsCategoriesOpen(true)}>
                <div className="settings-row-icon-wrap settings-row-icon-wrap--category">🏷️
                </div>
                <span className="settings-row-label">Categories</span>
                <span className="settings-row-value">{categories.length}</span>
                <span className="settings-row-arrow">›</span>
              </button>
              <div className="settings-row">
                <div className="settings-row-icon-wrap settings-row-icon-wrap--currency">$
                </div>
                <span className="settings-row-label">Base currency</span>
                <label className="settings-currency-picker">
                  <span className="settings-currency-text">{selectedCurrency}</span>
                  <select
                    className="settings-currency-select"
                    value={selectedCurrency}
                    onChange={(e) => setSelectedCurrency(e.target.value as CurrencyCode)}
                  >
                    {currencyOptions.map((currency) => (
                      <option key={currency.code} value={currency.code}>{currency.label}</option>
                    ))}
                  </select>
                </label>
              </div>
            </div>
          </div>

          <IonModal
            isOpen={isEnabledCurrenciesOpen}
            onDidDismiss={() => {
              setIsEnabledCurrenciesOpen(false);
              setCurrencySearchQuery('');
            }}
            className="settings-currencies-modal"
            mode="ios"
          >
            <div className="settings-currencies-search-header">
              <div className="settings-currencies-search-shell">
                <IonIcon icon={searchOutline} />
                <input
                  className="settings-currencies-search-input"
                  value={currencySearchQuery}
                  onChange={(e) => setCurrencySearchQuery(e.target.value)}
                  placeholder="Search currencies"
                  autoFocus
                />
              </div>
              <button
                className="settings-currencies-close"
                onClick={() => {
                  setIsEnabledCurrenciesOpen(false);
                  setCurrencySearchQuery('');
                }}
              >
                Close
              </button>
            </div>
            <IonContent className="settings-currencies-content">
              <div className="settings-currencies-body">
                <div className="settings-currencies-title-row">Currencies</div>
                {filteredCurrencyOptions.map((option) => {
                  const isBaseCurrency = option.code === selectedCurrency;
                  return (
                    <div
                      key={option.code}
                      className={`settings-currency-option${isBaseCurrency ? ' is-base' : ''}`}
                    >
                      <span className="settings-currency-option-main">
                        <span className="settings-currency-option-title">{option.label}</span>
                        <span className="settings-currency-option-subtitle">{getCurrencySubtitle(option.code)}</span>
                      </span>
                    </div>
                  );
                })}
                {filteredCurrencyOptions.length === 0 && (
                  <div className="settings-currencies-empty">No currencies found</div>
                )}
              </div>
            </IonContent>
          </IonModal>

          <IonModal
            isOpen={isCategoriesOpen}
            onDidDismiss={() => {
              setIsCategoriesOpen(false);
              setCategoriesSearchQuery('');
            }}
            className="settings-categories-modal"
            mode="ios"
          >
            <div className="settings-categories-search-header">
              <button
                className="settings-categories-create"
                onClick={handleOpenCreateCategoryModal}
              >
                Create
              </button>
              <div className="settings-categories-search-shell">
                <IonIcon icon={searchOutline} />
                <input
                  className="settings-categories-search-input"
                  value={categoriesSearchQuery}
                  onChange={(e) => setCategoriesSearchQuery(e.target.value)}
                  placeholder="Search categories"
                  autoFocus
                />
              </div>
              <button
                className="settings-categories-close"
                onClick={() => {
                  setIsCategoriesOpen(false);
                  setCategoriesSearchQuery('');
                }}
              >
                Close
              </button>
            </div>
            <IonContent className="settings-categories-content">
              <div className="settings-categories-body">
                {filteredCategories.length > 0 ? (
                  <div className="settings-categories-list">
                    {filteredCategories.map((category) => (
                      <div key={category.title} className="settings-category-row">
                        <span className="settings-category-emoji">{category.emoji}</span>
                        <span className="settings-category-title">{category.title}</span>
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className="settings-categories-empty">No categories found</div>
                )}
              </div>
            </IonContent>
          </IonModal>

          <IonModal
            isOpen={isCreateCategoryOpen}
            onDidDismiss={handleCreateCategoryModalDismiss}
            className="settings-create-category-modal"
            mode="ios"
            breakpoints={[0, 0.45, 1]}
            initialBreakpoint={0.45}
          >
            <IonContent className="settings-create-category-content">
              <div className="settings-create-category-body">
                <input
                  type="text"
                  className="settings-create-category-emoji-input"
                  value={newCategoryEmoji}
                  onChange={handleEmojiChange}
                  onFocus={(e) => e.target.select()}
                  onClick={(e) => e.currentTarget.select()}
                  placeholder="🙂"
                  maxLength={2}
                  autoFocus
                />

                {categoryCreationError && (
                  <div className="settings-create-category-error">{categoryCreationError}</div>
                )}

                <div className="settings-create-category-input-row">
                  <input
                    type="text"
                    className="settings-create-category-title-input"
                    value={newCategoryTitle}
                    maxLength={MAX_CATEGORY_TITLE_LENGTH}
                    onChange={(e) => {
                      setNewCategoryTitle(e.target.value);
                      setCategoryCreationError('');
                    }}
                    placeholder="Category Name"
                    onKeyDown={(e) => { if (e.key === 'Enter') handleCreateCategory(); }}
                  />
                  <button
                    className="settings-create-category-add-btn"
                    onClick={handleCreateCategory}
                    disabled={!newCategoryEmoji.trim() || !newCategoryTitle.trim()}
                  >
                    +
                  </button>
                </div>
              </div>
            </IonContent>
          </IonModal>

          <input
            ref={fileInputRef}
            type="file"
            accept="application/json"
            style={{ display: 'none' }}
            onChange={handleFileChange}
          />
        </div>
      </IonContent>
    </IonPage>
  );
};

export default Settings;
