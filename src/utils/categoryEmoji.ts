const CATEGORY_EMOJI_CANDIDATES = [
  '🙂', '😄', '😎', '🤖', '🧩', '🎯', '🎨', '🎵', '🎧', '🎬',
  '📚', '📝', '📦', '🛒', '🏠', '🔧', '💡', '🧠', '🪴', '🌿',
  '🌟', '🔥', '⚡', '🌈', '☕', '🍕', '🍣', '🍜', '🥗', '🍞',
  '🚗', '🚕', '🚌', '🚲', '✈️', '🚢', '🏝️', '🗺️', '🏨', '🎮',
  '🏋️', '⚽', '🏀', '🎾', '🧘', '💼', '💻', '📱', '🖥️', '⌚',
  '🔒', '🛟', '🧾', '💳', '🏦', '💰', '💎', '🪙', '🎁', '🪄',
  '🧸', '🛍️', '👕', '👟', '💄', '🧴', '🛏️', '🛋️', '🪑', '🚿',
  '🧼', '🧹', '🪛', '🔋', '🛰️', '📡', '🔬', '🧪', '🏥', '💊',
];

export const getRandomAvailableCategoryEmoji = (usedEmojis: string[]): string => {
  const excluded = new Set([...usedEmojis, '❓']);
  const available = CATEGORY_EMOJI_CANDIDATES.filter((emoji) => !excluded.has(emoji));

  if (available.length === 0) {
    return '';
  }

  const index = Math.floor(Math.random() * available.length);
  return available[index];
};