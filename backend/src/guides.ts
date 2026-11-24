// How-to guides on the public site, one per language, each written for a
// search with little competition that a new site can realistically rank for:
//
//   /split-receipt-by-item        "split a receipt by item"              (English)
//   /sr/podela-racuna             "podela računa"                        (Serbian, Latin)
//   /ru/kak-razdelit-schet        "как разделить счёт в ресторане"       (Russian)
//   /es/como-dividir-la-cuenta    "cómo dividir la cuenta"               (Spanish, Mexico)
//   /de/rechnung-teilen           "Rechnung teilen"                      (German)
//   /fr/partager-l-addition       "partager l'addition"                  (French)
//
// Each is a real answer, not a doorway page: when to split by item, the
// method step by step, a worked example whose numbers add up, shared dishes /
// tax / tip / discounts, an FAQ, and then the app. Each is written for its
// country's habits (VAT in the prices, how much people tip), not translated
// word for word. They cover the same topic, so they name each other as
// hreflang alternates (English is the x-default). The app's own interface is
// English only, and the non-English guides say so. Claims about the app
// match what it does: shared items split
// among whoever had them; service charges, fees and discounts spread in
// proportion to each person's items; a tip too once it is marked as one
// (see SplitShareCalculator.swift). Keep each FAQ and its FAQPage JSON-LD in
// sync — they are built from the same array.

import { seoHead, SITE_URL, APP_NAME, APP_STORE_URL, SUPPORT_EMAIL } from "./seo.ts";

export interface Faq {
  q: string;
  a: string;
}

export interface Guide {
  path: string;
  /** <html lang>. */
  lang: string;
  /** hreflang code the other guides use for this one. */
  hreflang: string;
  /** og:locale. */
  locale: string;
  /** This language's name in itself, for the language switcher. */
  languageName: string;
  title: string;
  description: string;
  eyebrow: string;
  h1: string;
  lede: string;
  /** The article between the lede and the FAQ (hand-written HTML). */
  body: string;
  faqHeading: string;
  faq: ReadonlyArray<Faq>;
  cta: string;
  alsoIn: string;
  nav: { home: string; privacy: string; support: string };
  /** First published (ISO date); also the Article's dateModified. */
  published: string;
}

const EN: Guide = {
  path: "/split-receipt-by-item",
  lang: "en",
  hreflang: "en",
  locale: "en_US",
  languageName: "English",
  title: "How to Split a Receipt by Item (Tax & Tip Included)",
  description:
    "Split a restaurant bill fairly: who had what, shared dishes, and tax and tip in proportion. A worked example, and how to do it in seconds on iPhone.",
  eyebrow: "Guide",
  h1: "How to split a receipt by item",
  lede: "Splitting a bill evenly is quick, but rarely fair: one friend had a salad and a lemonade, another had a steak and two beers. Splitting by item means everyone pays for what they ordered, plus their fair part of shared dishes, tax and tip. Here is how to do it by hand, with a worked example, and how to do it in a few taps.",
  body: `
    <section>
      <h2>When to split by item</h2>
      <p>Split evenly when everyone ordered about the same, or when the difference is one coffee. Split by item when orders differ a lot: someone isn't drinking, someone only had a starter, someone joined for dessert. It matters most with friends you eat out with every week, because small unfairness adds up.</p>
    </section>

    <section>
      <h2>Step by step</h2>
      <ol class="howto">
        <li><strong>Go through the receipt line by line.</strong> Next to each item, write the name of whoever had it.</li>
        <li><strong>Split the shared items.</strong> A pizza for the table or a bottle of wine is divided by the number of people who actually shared it, not by everyone at the table.</li>
        <li><strong>Add up each person's items.</strong> That is their subtotal. All the subtotals together equal the receipt's subtotal before tax and tip.</li>
        <li><strong>Share tax and tip in proportion.</strong> Whoever ordered 40% of the food pays 40% of the tax and 40% of the tip. The quick way: with a 15% tip, add 15% to each person's subtotal.</li>
        <li><strong>Check the total.</strong> Everyone's shares must add up to exactly what was paid. If rounding leaves a cent over, give it to one person.</li>
        <li><strong>Pay back.</strong> Whoever paid the bill gets paid back by everyone else, each their own amount.</li>
      </ol>
    </section>

    <section>
      <h2>A worked example</h2>
      <p>Anna, Ben and Chloe had dinner. The receipt says:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Item</th><th class="num">Price</th><th>Who had it</th></tr></thead>
        <tbody>
          <tr><td>Margherita pizza</td><td class="num">$15.00</td><td>Anna, Ben, Chloe</td></tr>
          <tr><td>Caesar salad</td><td class="num">$9.00</td><td>Anna</td></tr>
          <tr><td>Lemonade</td><td class="num">$4.00</td><td>Anna</td></tr>
          <tr><td>Steak</td><td class="num">$24.00</td><td>Ben</td></tr>
          <tr><td>2 × beer</td><td class="num">$12.00</td><td>Ben</td></tr>
          <tr><td>Pasta carbonara</td><td class="num">$13.00</td><td>Chloe</td></tr>
          <tr class="sub"><td>Subtotal</td><td class="num">$77.00</td><td></td></tr>
          <tr><td>Tax 8%</td><td class="num">$6.16</td><td></td></tr>
          <tr><td>Tip 15%</td><td class="num">$11.55</td><td></td></tr>
          <tr class="total"><td>Total</td><td class="num">$94.71</td><td></td></tr>
        </tbody>
      </table></div>
      <p>All three shared the pizza, so each gets $5.00 of it. Then:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Items</th><th class="num">Tax 8%</th><th class="num">Tip 15%</th><th class="num">Pays</th></tr></thead>
        <tbody>
          <tr><td>Anna</td><td class="num">$18.00</td><td class="num">$1.44</td><td class="num">$2.70</td><td class="num">$22.14</td></tr>
          <tr><td>Ben</td><td class="num">$41.00</td><td class="num">$3.28</td><td class="num">$6.15</td><td class="num">$50.43</td></tr>
          <tr><td>Chloe</td><td class="num">$18.00</td><td class="num">$1.44</td><td class="num">$2.70</td><td class="num">$22.14</td></tr>
          <tr class="total"><td>Total</td><td class="num">$77.00</td><td class="num">$6.16</td><td class="num">$11.55</td><td class="num">$94.71</td></tr>
        </tbody>
      </table></div>
      <p>Split evenly, each would pay $31.57: Anna and Chloe would each overpay by $9.43, and Ben would pay $18.86 less than his dinner cost.</p>
    </section>

    <section>
      <h2>Shared dishes, tax, tip and discounts</h2>
      <ul class="points">
        <li><strong>Shared dishes</strong> are split only among the people who had them. If two of five shared a bottle of wine, it is split in two.</li>
        <li><strong>Tax</strong> added on top of the prices, as in the US, is shared in proportion to each person's subtotal. Where prices already include VAT, as in most of Europe, there is nothing extra to share.</li>
        <li><strong>Tip and service charge</strong> are shared in proportion too, so whoever ordered more tips more. An equal tip is simpler, but then whoever ordered least tips the highest percentage of their own order.</li>
        <li><strong>Discounts</strong> go to whoever's items they apply to. A discount on the whole bill is shared in proportion, like tax.</li>
      </ul>
    </section>

    <section>
      <h2>Split a receipt by item in a few taps</h2>
      <p>A napkin and a calculator work, but take ten minutes. ${APP_NAME}, a free iPhone app, does it for you:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Scan the receipt</h3>
          <p>Take a photo of the receipt, or pick a screenshot of an online order. ${APP_NAME} reads each line, the prices and the total.</p>
        </div></div>
        <div class="step"><div>
          <h3>Tap who had what</h3>
          <p>Assign items to friends; shared items are split among whoever had them. Service charges, fees and discounts are spread in proportion automatically, and so is a tip once you mark it as one.</p>
        </div></div>
        <div class="step"><div>
          <h3>Settle up</h3>
          <p>Each share goes on a running balance with that friend, netted across every dinner and trip. Mark it settled when the money moves.</p>
        </div></div>
      </div>
      <p class="note">No bank login, no account and no ads. Your data stays on your iPhone.</p>
    </section>`,
  faqHeading: "Questions",
  faq: [
    {
      q: "Should the tip be split evenly or by what everyone ordered?",
      a: "By what everyone ordered, in proportion to each person's subtotal. The tip is a percentage of the food, so whoever ordered more owes more of it. An equal tip is fine when everyone ordered about the same.",
    },
    {
      q: "How do you split a shared dish?",
      a: "Divide its price by the number of people who actually shared it and add that piece to each of their subtotals. Whoever didn't have any pays nothing for it.",
    },
    {
      q: "What if the items don't add up to the receipt total?",
      a: "Look for a service charge, a discount or a cover charge on the receipt. Share whatever the difference is in proportion to each person's subtotal, the same way as tax.",
    },
    {
      q: "What if one person paid the whole bill?",
      a: "Everyone pays them back their own share. If you eat out with the same friends often, keep a running balance instead of paying back every time: Non Bank nets it across all your shared bills.",
    },
    {
      q: "Is there an app that splits a receipt by item?",
      a: "Yes. Non Bank is a free iPhone app: scan the receipt, tap who had what, and it works out every share, including shared items and the tip. It needs no account and no bank login.",
    },
  ],
  cta: "Get Non Bank free on the App Store",
  alsoIn: "Also in",
  nav: { home: "Home", privacy: "Privacy Policy", support: "Support" },
  published: "2026-11-14",
};

const SR: Guide = {
  path: "/sr/podela-racuna",
  lang: "sr-Latn",
  hreflang: "sr",
  locale: "sr_RS",
  languageName: "Srpski",
  title: "Podela računa u restoranu: kako podeliti po stavkama",
  description:
    "Kako pošteno podeliti račun: ko je šta naručio, zajednička jela i bakšiš srazmerno. Primer korak po korak i kako to uraditi za minut na iPhone-u.",
  eyebrow: "Vodič",
  h1: "Podela računa: kako podeliti račun po stavkama",
  lede: "Podeliti račun na jednake delove je brzo, ali retko pošteno: neko je uzeo samo salatu i limunadu, a neko pljeskavicu i dva piva. Kada se račun deli po stavkama, svako plaća ono što je naručio, plus svoj deo zajedničkih jela i bakšiša. Evo kako to da uradite ručno, na primeru, i kako u par dodira.",
  body: `
    <section>
      <h2>Kada deliti po stavkama</h2>
      <p>Na jednake delove delite kada su svi naručili otprilike isto ili kada je razlika jedna kafa. Po stavkama delite kada se porudžbine dosta razlikuju: neko ne pije, neko je uzeo samo predjelo, neko je stigao tek na desert. Najviše se isplati sa društvom sa kojim izlazite svake nedelje, jer se male nepravde brzo saberu.</p>
    </section>

    <section>
      <h2>Korak po korak</h2>
      <ol class="howto">
        <li><strong>Prođite kroz račun stavku po stavku.</strong> Pored svake stavke upišite ko ju je naručio.</li>
        <li><strong>Podelite zajedničke stavke.</strong> Pica za ceo sto ili flaša vina deli se na broj ljudi koji su je zaista delili, a ne na ceo sto.</li>
        <li><strong>Saberite stavke svake osobe.</strong> To je njen međuzbir. Svi međuzbirovi zajedno daju iznos računa pre bakšiša.</li>
        <li><strong>Bakšiš podelite srazmerno.</strong> Ko je naručio 40% računa, daje i 40% bakšiša. Najlakše: ako ostavljate 10%, svakome dodajte 10% na njegov međuzbir.</li>
        <li><strong>Proverite zbir.</strong> Delovi svih zajedno moraju da daju tačno onoliko koliko je plaćeno. Ako posle zaokruživanja ostane dinar viška, prepišite ga jednoj osobi.</li>
        <li><strong>Vratite novac.</strong> Ko je platio račun, ostali mu vraćaju svako svoj deo.</li>
      </ol>
    </section>

    <section>
      <h2>Primer</h2>
      <p>Ana, Marko i Jelena su bili na večeri. Na računu piše:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Stavka</th><th class="num">Cena, din.</th><th>Ko je naručio</th></tr></thead>
        <tbody>
          <tr><td>Pica margarita</td><td class="num">1.500</td><td>Ana, Marko, Jelena</td></tr>
          <tr><td>Šopska salata</td><td class="num">450</td><td>Ana</td></tr>
          <tr><td>Limunada</td><td class="num">250</td><td>Ana</td></tr>
          <tr><td>Pljeskavica</td><td class="num">900</td><td>Marko</td></tr>
          <tr><td>2 × pivo</td><td class="num">600</td><td>Marko</td></tr>
          <tr><td>Pasta karbonara</td><td class="num">1.100</td><td>Jelena</td></tr>
          <tr class="total"><td>Ukupno</td><td class="num">4.800</td><td></td></tr>
        </tbody>
      </table></div>
      <p>PDV je u Srbiji već uračunat u cene, pa ga posebno ne delite. Ostavljaju 10% bakšiša, 480 dinara. Picu su delili svi troje, pa svako od nje plaća po 500 dinara. Onda:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Stavke</th><th class="num">Bakšiš 10%</th><th class="num">Plaća</th></tr></thead>
        <tbody>
          <tr><td>Ana</td><td class="num">1.200</td><td class="num">120</td><td class="num">1.320</td></tr>
          <tr><td>Marko</td><td class="num">2.000</td><td class="num">200</td><td class="num">2.200</td></tr>
          <tr><td>Jelena</td><td class="num">1.600</td><td class="num">160</td><td class="num">1.760</td></tr>
          <tr class="total"><td>Ukupno</td><td class="num">4.800</td><td class="num">480</td><td class="num">5.280</td></tr>
        </tbody>
      </table></div>
      <p>Da su račun podelili na jednake delove, svako bi platio 1.760 dinara: Ana bi dala 440 dinara više od svog dela, a Marko 440 manje.</p>
    </section>

    <section>
      <h2>Zajednička jela, bakšiš, PDV i popusti</h2>
      <ul class="points">
        <li><strong>Zajednička jela</strong> delite samo na one koji su ih jeli. Ako su dvoje od petoro delili flašu vina, ona se deli na dvoje.</li>
        <li><strong>Bakšiš i naknadu za uslugu</strong> delite srazmerno, pa onaj ko je naručio više daje i više. Jednak bakšiš je jednostavniji, ali tada onaj ko je najmanje naručio ostavlja najveći procenat svoje porudžbine.</li>
        <li><strong>PDV</strong> je u Srbiji i većem delu Evrope već uračunat u cene, pa nema šta dodatno da se deli. Ako je porez na računu dodat posebno, kao u SAD, delite ga srazmerno, kao bakšiš.</li>
        <li><strong>Popust</strong> ide onome na čije se stavke odnosi. Popust na ceo račun delite srazmerno, kao bakšiš.</li>
      </ul>
    </section>

    <section>
      <h2>Podelite račun u par dodira</h2>
      <p>Na salveti se može, ali traje deset minuta i treba kalkulator. ${APP_NAME}, besplatna aplikacija za iPhone, radi to umesto vas:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Skenirajte račun</h3>
          <p>Fotografišite račun ili izaberite snimak ekrana porudžbine iz aplikacije za dostavu. ${APP_NAME} čita svaku stavku, cene i ukupan iznos, i na latinici i na ćirilici.</p>
        </div></div>
        <div class="step"><div>
          <h3>Označite ko je šta naručio</h3>
          <p>Dodelite stavke prijateljima; zajedničke se dele na one koji su ih delili. Naknade za uslugu i popusti dele se srazmerno automatski, a isto važi i za bakšiš kada ga označite kao bakšiš.</p>
        </div></div>
        <div class="step"><div>
          <h3>Izmirite dugove</h3>
          <p>Svačiji deo ide u stanje sa tim prijateljem, sabrano preko svih večera i putovanja. Kada vam vrate novac, označite dug kao izmiren.</p>
        </div></div>
      </div>
      <p class="note">Bez prijave u banku, bez naloga i bez reklama. Podaci ostaju na vašem iPhone-u. Aplikacija je za sada na engleskom jeziku.</p>
    </section>`,
  faqHeading: "Pitanja",
  faq: [
    {
      q: "Da li se bakšiš deli na jednake delove ili po porudžbini?",
      a: "Po porudžbini, srazmerno međuzbiru svake osobe. Bakšiš je procenat od računa, pa ko je naručio više, daje i više. Jednak bakšiš je u redu kada su svi naručili otprilike isto.",
    },
    {
      q: "Kako se deli zajedničko jelo?",
      a: "Cenu podelite na broj ljudi koji su ga zaista jeli i dodajte taj deo svakome od njih. Ko nije jeo, ne plaća ništa.",
    },
    {
      q: "Šta ako se stavke ne slažu sa ukupnim iznosom?",
      a: "Potražite na računu naknadu za uslugu, popust ili kuver. Razliku podelite srazmerno međuzbirovima, kao bakšiš.",
    },
    {
      q: "Šta ako je jedna osoba platila ceo račun?",
      a: "Ostali joj vraćaju svako svoj deo. Ako često izlazite sa istim društvom, umesto vraćanja posle svake večere vodite stanje: Non Bank sabira dugovanja preko svih zajedničkih računa.",
    },
    {
      q: "Postoji li aplikacija za podelu računa po stavkama?",
      a: "Da. Non Bank je besplatna aplikacija za iPhone: skenirate račun, označite ko je šta naručio, a ona izračuna svačiji deo, sa zajedničkim stavkama i bakšišem. Ne traži nalog ni prijavu u banku.",
    },
  ],
  cta: "Preuzmite Non Bank besplatno na App Store-u",
  alsoIn: "Takođe na",
  nav: { home: "Početna", privacy: "Politika privatnosti", support: "Podrška" },
  published: "2026-11-14",
};

const RU: Guide = {
  path: "/ru/kak-razdelit-schet",
  lang: "ru",
  hreflang: "ru",
  locale: "ru_RU",
  languageName: "Русский",
  title: "Как разделить счёт в ресторане: по позициям и честно",
  description:
    "Как поделить счёт в ресторане: кто что заказывал, общие блюда и чаевые пропорционально. Пример с расчётом и как сделать это за минуту на iPhone.",
  eyebrow: "Гайд",
  h1: "Как разделить счёт в ресторане по позициям",
  lede: "Поделить счёт поровну быстро, но редко честно: кто-то взял салат и лимонад, а кто-то стейк и два пива. Если делить по позициям, каждый платит за то, что заказал, плюс свою долю общих блюд и чаевых. Ниже — как сделать это вручную на примере и как за пару касаний.",
  body: `
    <section>
      <h2>Когда делить по позициям</h2>
      <p>Поровну стоит делить, когда все заказали примерно одинаково или разница — одна чашка кофе. По позициям — когда заказы сильно отличаются: кто-то не пьёт, кто-то взял только закуску, кто-то пришёл к десерту. Особенно это важно с компанией, с которой вы ужинаете каждую неделю: мелкая несправедливость быстро накапливается.</p>
    </section>

    <section>
      <h2>По шагам</h2>
      <ol class="howto">
        <li><strong>Пройдитесь по чеку построчно.</strong> Возле каждой позиции отметьте, кто её заказал.</li>
        <li><strong>Разделите общие позиции.</strong> Пиццу на всех или бутылку вина делят на тех, кто их действительно ел и пил, а не на весь стол.</li>
        <li><strong>Сложите позиции каждого.</strong> Получится его подытог. Все подытоги вместе дают сумму чека до чаевых.</li>
        <li><strong>Чаевые делите пропорционально.</strong> Кто заказал на 40% чека, тот и оставляет 40% чаевых. Проще всего: если оставляете 10%, прибавьте 10% к подытогу каждого.</li>
        <li><strong>Проверьте сумму.</strong> Доли всех вместе должны дать ровно ту сумму, которую заплатили. Если после округления остался лишний рубль, запишите его на одного человека.</li>
        <li><strong>Рассчитайтесь.</strong> Тому, кто оплатил счёт, остальные переводят каждый свою долю.</li>
      </ol>
    </section>

    <section>
      <h2>Пример</h2>
      <p>Аня, Боря и Вика поужинали вместе. В чеке:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Позиция</th><th class="num">Цена, ₽</th><th>Кто заказывал</th></tr></thead>
        <tbody>
          <tr><td>Пицца «Маргарита»</td><td class="num">1&nbsp;500</td><td>Аня, Боря, Вика</td></tr>
          <tr><td>Салат «Цезарь»</td><td class="num">650</td><td>Аня</td></tr>
          <tr><td>Лимонад</td><td class="num">300</td><td>Аня</td></tr>
          <tr><td>Стейк</td><td class="num">1&nbsp;900</td><td>Боря</td></tr>
          <tr><td>2 × пиво</td><td class="num">800</td><td>Боря</td></tr>
          <tr><td>Паста карбонара</td><td class="num">850</td><td>Вика</td></tr>
          <tr class="total"><td>Итого</td><td class="num">6&nbsp;000</td><td></td></tr>
        </tbody>
      </table></div>
      <p>НДС в России уже включён в цены, отдельно его делить не нужно. Чаевые — 10%, то есть 600&nbsp;₽. Пиццу ели все трое, так что за неё каждый платит по 500&nbsp;₽. Дальше:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Позиции</th><th class="num">Чаевые 10%</th><th class="num">Платит</th></tr></thead>
        <tbody>
          <tr><td>Аня</td><td class="num">1&nbsp;450</td><td class="num">145</td><td class="num">1&nbsp;595</td></tr>
          <tr><td>Боря</td><td class="num">3&nbsp;200</td><td class="num">320</td><td class="num">3&nbsp;520</td></tr>
          <tr><td>Вика</td><td class="num">1&nbsp;350</td><td class="num">135</td><td class="num">1&nbsp;485</td></tr>
          <tr class="total"><td>Итого</td><td class="num">6&nbsp;000</td><td class="num">600</td><td class="num">6&nbsp;600</td></tr>
        </tbody>
      </table></div>
      <p>Если бы делили поровну, каждый заплатил бы по 2&nbsp;200&nbsp;₽: Аня переплатила бы 605&nbsp;₽, Вика — 715&nbsp;₽, а Боря заплатил бы на 1&nbsp;320&nbsp;₽ меньше, чем стоил его ужин.</p>
    </section>

    <section>
      <h2>Общие блюда, чаевые, обслуживание и скидки</h2>
      <ul class="points">
        <li><strong>Общие блюда</strong> делят только на тех, кто их ел. Если бутылку вина пили двое из пяти, её делят на двоих.</li>
        <li><strong>Чаевые и плату за обслуживание</strong> делят пропорционально: кто заказал больше, тот и оставляет больше. Одинаковые чаевые проще, но тогда тот, кто заказал меньше всех, оставляет самый большой процент от своего заказа.</li>
        <li><strong>НДС</strong> в России и большинстве стран Европы уже входит в цены. Если налог добавлен в чеке отдельно, как в США, его делят так же пропорционально.</li>
        <li><strong>Скидку</strong> получает тот, к чьим позициям она относится. Скидку на весь чек делят пропорционально, как чаевые.</li>
      </ul>
    </section>

    <section>
      <h2>Разделить чек за пару касаний</h2>
      <p>На салфетке тоже можно, но это десять минут и калькулятор. ${APP_NAME} — бесплатное приложение для iPhone — сделает это за вас:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Отсканируйте чек</h3>
          <p>Сфотографируйте чек или выберите скриншот заказа из приложения доставки. ${APP_NAME} читает каждую позицию, цены и итог, в том числе на кириллице.</p>
        </div></div>
        <div class="step"><div>
          <h3>Отметьте, кто что заказывал</h3>
          <p>Распределите позиции между друзьями; общие делятся на тех, кто их разделил. Плата за обслуживание, сборы и скидки распределяются пропорционально автоматически, чаевые тоже — если отметить их как чаевые.</p>
        </div></div>
        <div class="step"><div>
          <h3>Рассчитайтесь</h3>
          <p>Доля каждого попадает в общий баланс с этим другом, с учётом всех ужинов и поездок. Когда деньги вернули, отметьте долг погашенным.</p>
        </div></div>
      </div>
      <p class="note">Без входа в банк, без аккаунта и без рекламы. Данные хранятся на вашем iPhone. Интерфейс приложения пока на английском.</p>
    </section>`,
  faqHeading: "Вопросы",
  faq: [
    {
      q: "Как делить чаевые — поровну или по заказу?",
      a: "По заказу, пропорционально подытогу каждого. Чаевые — это процент от счёта, поэтому кто заказал больше, тот и оставляет больше. Поровну можно, если все заказали примерно одинаково.",
    },
    {
      q: "Как разделить общее блюдо?",
      a: "Разделите его цену на число тех, кто его действительно ел, и прибавьте эту часть каждому из них. Кто не ел, ничего за него не платит.",
    },
    {
      q: "Что делать, если позиции не сходятся с итогом?",
      a: "Поищите в чеке плату за обслуживание, скидку или сервисный сбор. Разницу разделите пропорционально подытогам, как чаевые.",
    },
    {
      q: "Что если весь счёт оплатил один человек?",
      a: "Остальные возвращают ему каждый свою долю. Если вы часто ужинаете одной компанией, удобнее вести общий баланс, а не переводить деньги после каждого ужина: Non Bank сводит долги по всем общим счетам.",
    },
    {
      q: "Есть ли приложение, чтобы разделить чек по позициям?",
      a: "Да. Non Bank — бесплатное приложение для iPhone: сканируете чек, отмечаете, кто что заказывал, и оно считает долю каждого с общими блюдами и чаевыми. Без аккаунта и без входа в банк.",
    },
  ],
  cta: "Скачать Non Bank бесплатно в App Store",
  alsoIn: "Читать на",
  nav: { home: "Главная", privacy: "Политика конфиденциальности", support: "Поддержка" },
  published: "2026-11-14",
};

// The App Store page is localized for Mexico (es-MX), so the example is a
// Mexican dinner in pesos; the advice holds for Spain too (IVA is in the
// prices in both). "Cuenta" is the bill here, so "account" is avoided:
// "sin registrarte" instead.
const ES: Guide = {
  path: "/es/como-dividir-la-cuenta",
  lang: "es",
  hreflang: "es",
  locale: "es_MX",
  languageName: "Español",
  title: "Cómo dividir la cuenta en un restaurante, con propina",
  description:
    "Divide la cuenta de forma justa: lo que pidió cada uno, platos compartidos y propina proporcional. Un ejemplo con números y cómo hacerlo en el iPhone.",
  eyebrow: "Guía",
  h1: "Cómo dividir la cuenta según lo que pidió cada uno",
  lede: "Dividir la cuenta en partes iguales es rápido, pero pocas veces es justo: alguien pidió unos tacos y un agua de jamaica, y otro una arrachera y dos cervezas. Dividirla por consumo significa que cada uno paga lo que pidió, más su parte justa de los platos compartidos y de la propina. Aquí te explicamos cómo hacerlo a mano, con un ejemplo, y cómo hacerlo en unos cuantos toques.",
  body: `
    <section>
      <h2>Cuándo dividir por consumo</h2>
      <p>Divide en partes iguales cuando todos pidieron más o menos lo mismo, o cuando la diferencia es un café. Divide por consumo cuando los pedidos son muy distintos: alguien no toma alcohol, alguien solo pidió una entrada, alguien llegó para el postre. Importa sobre todo con los amigos con los que sales cada semana, porque las pequeñas injusticias se van sumando.</p>
    </section>

    <section>
      <h2>Paso a paso</h2>
      <ol class="howto">
        <li><strong>Revisa la cuenta línea por línea.</strong> Junto a cada plato o bebida, anota el nombre de quien lo pidió.</li>
        <li><strong>Divide lo compartido.</strong> Una pizza para la mesa o una botella de vino se divide entre quienes de verdad la compartieron, no entre toda la mesa.</li>
        <li><strong>Suma lo de cada persona.</strong> Ese es su subtotal. Todos los subtotales juntos dan el total de la cuenta antes de la propina.</li>
        <li><strong>Reparte la propina en proporción.</strong> Quien pidió el 40% de la cuenta deja el 40% de la propina. Lo más fácil: si dejan el 10%, suma un 10% al subtotal de cada uno.</li>
        <li><strong>Comprueba el total.</strong> Las partes de todos deben sumar exactamente lo que se pagó. Si al redondear sobra un peso, asígnaselo a una persona.</li>
        <li><strong>Págale a quien pagó.</strong> Si una persona pagó toda la cuenta, cada uno le devuelve su parte.</li>
      </ol>
    </section>

    <section>
      <h2>Un ejemplo con números</h2>
      <p>Lucía, Diego y Sofía fueron a cenar. La cuenta dice:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Consumo</th><th class="num">Precio (MXN)</th><th>Quién lo pidió</th></tr></thead>
        <tbody>
          <tr><td>Guacamole para compartir</td><td class="num">$150</td><td>Lucía, Diego, Sofía</td></tr>
          <tr><td>Tacos al pastor</td><td class="num">$120</td><td>Lucía</td></tr>
          <tr><td>Agua de jamaica</td><td class="num">$40</td><td>Lucía</td></tr>
          <tr><td>Arrachera</td><td class="num">$260</td><td>Diego</td></tr>
          <tr><td>2 × cerveza</td><td class="num">$130</td><td>Diego</td></tr>
          <tr><td>Enchiladas suizas</td><td class="num">$200</td><td>Sofía</td></tr>
          <tr class="total"><td>Total</td><td class="num">$900</td><td></td></tr>
        </tbody>
      </table></div>
      <p>En México el IVA ya viene incluido en los precios, así que no hay que repartirlo aparte. Dejan 10% de propina, es decir, $90. El guacamole lo compartieron los tres, así que a cada uno le tocan $50. Entonces:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Consumo</th><th class="num">Propina 10%</th><th class="num">Paga</th></tr></thead>
        <tbody>
          <tr><td>Lucía</td><td class="num">$210</td><td class="num">$21</td><td class="num">$231</td></tr>
          <tr><td>Diego</td><td class="num">$440</td><td class="num">$44</td><td class="num">$484</td></tr>
          <tr><td>Sofía</td><td class="num">$250</td><td class="num">$25</td><td class="num">$275</td></tr>
          <tr class="total"><td>Total</td><td class="num">$900</td><td class="num">$90</td><td class="num">$990</td></tr>
        </tbody>
      </table></div>
      <p>Si hubieran dividido en partes iguales, cada uno habría pagado $330: Lucía habría pagado $99 de más, Sofía $55 de más, y Diego $154 menos de lo que costó su cena.</p>
    </section>

    <section>
      <h2>Platos compartidos, propina, IVA y descuentos</h2>
      <ul class="points">
        <li><strong>Los platos compartidos</strong> se dividen solo entre quienes los comieron. Si dos de cinco compartieron una botella de vino, se divide entre dos.</li>
        <li><strong>La propina y el cargo por servicio</strong> se reparten en proporción, así que quien pidió más deja más. Una propina igual para todos es más simple, pero entonces quien pidió menos deja el porcentaje más alto de su propio consumo. Si la cuenta ya incluye el servicio, no lo dejes dos veces.</li>
        <li><strong>El IVA</strong> ya está incluido en los precios en México y en España, así que no hay nada extra que repartir. Si el impuesto se suma aparte, como en Estados Unidos, se reparte en proporción, igual que la propina.</li>
        <li><strong>Los descuentos</strong> son para quien pidió los productos a los que se aplican. Un descuento sobre toda la cuenta se reparte en proporción, como la propina.</li>
      </ul>
    </section>

    <section>
      <h2>Divide la cuenta en unos cuantos toques</h2>
      <p>Con una servilleta y la calculadora del teléfono se puede, pero toma diez minutos. ${APP_NAME}, una app gratuita para iPhone, lo hace por ti:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Escanea la cuenta</h3>
          <p>Toma una foto del ticket o elige una captura de pantalla de un pedido en línea. ${APP_NAME} lee cada línea, los precios y el total, incluidos los tickets en español.</p>
        </div></div>
        <div class="step"><div>
          <h3>Marca quién pidió qué</h3>
          <p>Asigna cada producto a tus amigos; lo compartido se divide entre quienes lo compartieron. Los cargos por servicio, las comisiones y los descuentos se reparten en proporción automáticamente, y la propina también, en cuanto la marcas como propina.</p>
        </div></div>
        <div class="step"><div>
          <h3>Salda cuentas</h3>
          <p>La parte de cada uno se suma al saldo que llevas con ese amigo, compensado entre todas las cenas y viajes. Márcalo como saldado cuando llegue el dinero.</p>
        </div></div>
      </div>
      <p class="note">Sin conectar tu banco, sin registrarte y sin anuncios. Tus datos se quedan en tu iPhone. Por ahora la app está en inglés.</p>
    </section>`,
  faqHeading: "Preguntas frecuentes",
  faq: [
    {
      q: "¿La propina se divide en partes iguales o según lo que pidió cada uno?",
      a: "Según lo que pidió cada uno, en proporción a su subtotal. La propina es un porcentaje del consumo, así que quien pidió más deja más. Dividirla en partes iguales está bien cuando todos pidieron más o menos lo mismo.",
    },
    {
      q: "¿Cuánta propina se deja en México?",
      a: "Lo habitual es entre el 10 y el 15% del consumo, según el servicio. Antes de calcularla, revisa que la cuenta no incluya ya el servicio, para no dejarlo dos veces.",
    },
    {
      q: "¿Cómo se divide un plato compartido?",
      a: "Divide su precio entre el número de personas que de verdad lo compartieron y suma esa parte al subtotal de cada una. Quien no lo probó no paga nada por él.",
    },
    {
      q: "¿Qué hago si los productos no suman el total de la cuenta?",
      a: "Busca en la cuenta un cargo por servicio, un descuento o una propina ya incluida. Reparte la diferencia en proporción al subtotal de cada uno, igual que la propina.",
    },
    {
      q: "¿Y si una sola persona pagó toda la cuenta?",
      a: "Cada uno le devuelve su parte. Si sales con frecuencia con los mismos amigos, en vez de devolver el dinero después de cada cena, lleva un saldo: Non Bank lo compensa entre todas las cuentas compartidas.",
    },
    {
      q: "¿Hay una app para dividir la cuenta por consumo?",
      a: "Sí. Non Bank es una app gratuita para iPhone: escaneas el ticket, marcas quién pidió qué y calcula la parte de cada uno, con platos compartidos y propina. No necesitas registrarte ni conectar tu banco.",
    },
  ],
  cta: "Descarga Non Bank gratis en el App Store",
  alsoIn: "También en",
  nav: { home: "Inicio", privacy: "Política de privacidad", support: "Soporte" },
  published: "2026-11-24",
};

// In Germany the waiter often asks "Zusammen oder getrennt?" and splits at
// the table, so the case for doing it yourself is the one where a single
// person pays. "Konto" means a bank account, so: "keine Registrierung".
const DE: Guide = {
  path: "/de/rechnung-teilen",
  lang: "de",
  hreflang: "de",
  locale: "de_DE",
  languageName: "Deutsch",
  title: "Rechnung teilen im Restaurant: fair, mit Trinkgeld",
  description:
    "So teilst du die Rechnung fair: wer was hatte, geteilte Gerichte und Trinkgeld anteilig. Mit Rechenbeispiel – und wie es auf dem iPhone in Sekunden geht.",
  eyebrow: "Ratgeber",
  h1: "Rechnung teilen: So zahlt jeder, was er bestellt hat",
  lede: "Die Rechnung einfach durch alle zu teilen geht schnell, ist aber selten fair: Die eine hatte nur einen Salat und eine Apfelschorle, der andere ein Schnitzel und zwei Weizen. Teilt ihr nach Bestellung, zahlt jeder, was er bestellt hat, plus seinen fairen Anteil an geteilten Gerichten und am Trinkgeld. Hier steht, wie das von Hand geht, mit einem Rechenbeispiel, und wie es mit ein paar Fingertipps klappt.",
  body: `
    <section>
      <h2>Wann nach Bestellung teilen?</h2>
      <p>Gleichmäßig zu teilen reicht, wenn alle ungefähr dasselbe bestellt haben oder der Unterschied ein Kaffee ist. Nach Bestellung teilen solltest du, wenn die Bestellungen weit auseinanderliegen: Jemand trinkt keinen Alkohol, jemand hatte nur eine Vorspeise, jemand kam erst zum Dessert. Oft fragt die Bedienung ohnehin „Zusammen oder getrennt?“. Selbst rechnen musst du, wenn einer alles bezahlt: bei großen Gruppen, mit einer Karte für alle, bei einer Lieferbestellung oder im Urlaub. Besonders lohnt es sich mit Freunden, mit denen du jede Woche essen gehst, denn kleine Ungerechtigkeiten summieren sich.</p>
    </section>

    <section>
      <h2>Schritt für Schritt</h2>
      <ol class="howto">
        <li><strong>Geh die Rechnung Zeile für Zeile durch.</strong> Schreib neben jede Position, wer sie bestellt hat.</li>
        <li><strong>Teile, was geteilt wurde.</strong> Eine Pizza für den Tisch oder eine Flasche Wein wird durch die Zahl der Leute geteilt, die wirklich etwas davon hatten, nicht durch alle am Tisch.</li>
        <li><strong>Rechne zusammen, was jeder hatte.</strong> Das ist seine Zwischensumme. Alle Zwischensummen zusammen ergeben den Rechnungsbetrag vor dem Trinkgeld.</li>
        <li><strong>Verteile das Trinkgeld anteilig.</strong> Wer 40&nbsp;% der Rechnung bestellt hat, gibt auch 40&nbsp;% des Trinkgelds. Am einfachsten: Bei 10&nbsp;% Trinkgeld schlägst du auf jede Zwischensumme 10&nbsp;% auf.</li>
        <li><strong>Prüf die Summe.</strong> Alle Anteile zusammen müssen genau den bezahlten Betrag ergeben. Bleibt nach dem Runden ein Cent übrig, schreib ihn einer Person zu.</li>
        <li><strong>Zurückzahlen.</strong> Wer die Rechnung bezahlt hat, bekommt von allen anderen ihren jeweiligen Anteil zurück.</li>
      </ol>
    </section>

    <section>
      <h2>Ein Rechenbeispiel</h2>
      <p>Lena, Jonas und Mia waren zusammen essen. Auf der Rechnung steht:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Position</th><th class="num">Preis</th><th>Für wen</th></tr></thead>
        <tbody>
          <tr><td>Pizza Margherita</td><td class="num">12,00&nbsp;€</td><td>Lena, Jonas, Mia</td></tr>
          <tr><td>Gemischter Salat</td><td class="num">8,50&nbsp;€</td><td>Lena</td></tr>
          <tr><td>Apfelschorle</td><td class="num">3,50&nbsp;€</td><td>Lena</td></tr>
          <tr><td>Schnitzel mit Pommes</td><td class="num">18,50&nbsp;€</td><td>Jonas</td></tr>
          <tr><td>2 × Weizenbier</td><td class="num">9,50&nbsp;€</td><td>Jonas</td></tr>
          <tr><td>Spaghetti Carbonara</td><td class="num">14,00&nbsp;€</td><td>Mia</td></tr>
          <tr class="total"><td>Summe</td><td class="num">66,00&nbsp;€</td><td></td></tr>
        </tbody>
      </table></div>
      <p>Die Mehrwertsteuer ist in Deutschland schon in den Preisen enthalten, die muss also niemand extra aufteilen. Sie geben 10&nbsp;% Trinkgeld, also 6,60&nbsp;€. Die Pizza haben sich alle drei geteilt, also zahlt jeder 4,00&nbsp;€ davon. Dann:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Bestellt</th><th class="num">Trinkgeld 10&nbsp;%</th><th class="num">Zahlt</th></tr></thead>
        <tbody>
          <tr><td>Lena</td><td class="num">16,00&nbsp;€</td><td class="num">1,60&nbsp;€</td><td class="num">17,60&nbsp;€</td></tr>
          <tr><td>Jonas</td><td class="num">32,00&nbsp;€</td><td class="num">3,20&nbsp;€</td><td class="num">35,20&nbsp;€</td></tr>
          <tr><td>Mia</td><td class="num">18,00&nbsp;€</td><td class="num">1,80&nbsp;€</td><td class="num">19,80&nbsp;€</td></tr>
          <tr class="total"><td>Summe</td><td class="num">66,00&nbsp;€</td><td class="num">6,60&nbsp;€</td><td class="num">72,60&nbsp;€</td></tr>
        </tbody>
      </table></div>
      <p>Hätten sie gleichmäßig geteilt, hätte jeder 24,20&nbsp;€ gezahlt: Lena 6,60&nbsp;€ zu viel, Mia 4,40&nbsp;€ zu viel, und Jonas 11,00&nbsp;€ weniger, als sein Essen gekostet hat.</p>
    </section>

    <section>
      <h2>Geteilte Gerichte, Trinkgeld, Mehrwertsteuer und Rabatte</h2>
      <ul class="points">
        <li><strong>Geteilte Gerichte</strong> werden nur unter denen aufgeteilt, die davon hatten. Haben sich zwei von fünf eine Flasche Wein geteilt, wird sie durch zwei geteilt.</li>
        <li><strong>Trinkgeld und Servicegebühren</strong> werden anteilig verteilt: Wer mehr bestellt hat, gibt mehr. Gleiches Trinkgeld für alle ist einfacher, aber dann gibt, wer am wenigsten bestellt hat, den höchsten Prozentsatz seiner eigenen Bestellung. Rundet ihr einfach auf, ist die Differenz zur Rechnung das Trinkgeld, und auch die lässt sich anteilig verteilen.</li>
        <li><strong>Die Mehrwertsteuer</strong> ist in Deutschland und fast ganz Europa schon im Preis enthalten, da gibt es nichts zusätzlich aufzuteilen. Wird eine Steuer erst auf der Rechnung aufgeschlagen, wie in den USA, verteilst du sie anteilig, wie das Trinkgeld.</li>
        <li><strong>Rabatte</strong> bekommt, wessen Positionen sie betreffen. Ein Rabatt auf die ganze Rechnung wird anteilig verteilt, wie das Trinkgeld.</li>
      </ul>
    </section>

    <section>
      <h2>Rechnung teilen mit ein paar Fingertipps</h2>
      <p>Mit Bierdeckel und Taschenrechner geht es auch, dauert aber zehn Minuten. ${APP_NAME}, eine kostenlose iPhone-App, erledigt das für dich:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Rechnung scannen</h3>
          <p>Fotografiere die Rechnung oder den Kassenbon, oder wähle einen Screenshot einer Online-Bestellung. ${APP_NAME} liest jede Position, die Preise und die Summe, auch auf deutschen Belegen.</p>
        </div></div>
        <div class="step"><div>
          <h3>Antippen, wer was hatte</h3>
          <p>Ordne die Positionen deinen Freunden zu; Geteiltes wird unter denen aufgeteilt, die es geteilt haben. Servicegebühren, Zuschläge und Rabatte werden automatisch anteilig verteilt, das Trinkgeld auch, sobald du es als Trinkgeld markierst.</p>
        </div></div>
        <div class="step"><div>
          <h3>Abrechnen</h3>
          <p>Jeder Anteil landet im laufenden Saldo mit diesem Freund, verrechnet über alle Abendessen und Reisen. Ist das Geld da, markierst du die Schuld als beglichen.</p>
        </div></div>
      </div>
      <p class="note">Kein Bank-Login, keine Registrierung, keine Werbung. Deine Daten bleiben auf deinem iPhone. Die App gibt es bisher nur auf Englisch.</p>
    </section>`,
  faqHeading: "Häufige Fragen",
  faq: [
    {
      q: "Teilt man das Trinkgeld gleichmäßig oder nach Bestellung?",
      a: "Nach Bestellung, anteilig zur Zwischensumme jedes Einzelnen. Das Trinkgeld ist ein Prozentsatz der Rechnung, also gibt mehr, wer mehr bestellt hat. Gleichmäßig ist in Ordnung, wenn alle ungefähr dasselbe hatten.",
    },
    {
      q: "Wie viel Trinkgeld gibt man in Deutschland?",
      a: "Üblich sind etwa 5 bis 10 %, oft wird einfach aufgerundet. Den Betrag mit Trinkgeld sagst du beim Bezahlen gleich mit an, zum Beispiel „Machen Sie 30“ bei einer Rechnung über 27,40 €.",
    },
    {
      q: "Wie rechnet man ein Gericht ab, das sich mehrere geteilt haben?",
      a: "Teile den Preis durch die Zahl der Leute, die wirklich davon gegessen haben, und rechne jedem von ihnen diesen Anteil zu. Wer nichts davon hatte, zahlt dafür nichts.",
    },
    {
      q: "Was, wenn die Positionen nicht die Rechnungssumme ergeben?",
      a: "Such auf der Rechnung nach einer Servicegebühr, einem Rabatt oder einem Gutschein. Verteile die Differenz anteilig zu den Zwischensummen, genau wie das Trinkgeld.",
    },
    {
      q: "Was, wenn einer die ganze Rechnung bezahlt hat?",
      a: "Alle anderen zahlen ihm ihren Anteil zurück. Wenn ihr oft mit denselben Leuten essen geht, führt lieber einen laufenden Saldo, statt jedes Mal zurückzuzahlen: Non Bank verrechnet ihn über alle gemeinsamen Rechnungen.",
    },
    {
      q: "Gibt es eine App, um die Rechnung nach Bestellung zu teilen?",
      a: "Ja. Non Bank ist eine kostenlose iPhone-App: Rechnung scannen, antippen, wer was hatte, und sie berechnet jeden Anteil, mit geteilten Positionen und Trinkgeld. Ohne Registrierung und ohne Bank-Login.",
    },
  ],
  cta: "Non Bank kostenlos im App Store laden",
  alsoIn: "Auch auf",
  nav: { home: "Startseite", privacy: "Datenschutz", support: "Support" },
  published: "2026-11-24",
};

// In France service is included in the prices ("service compris") and a tip
// is optional, so the example has none and instead shows the other common
// unfairness: a bottle of wine split among only the people who drank it.
// French typography puts a non-breaking space before : ; ? ! — &nbsp; in
// the HTML fields,   in the plain-text ones (title, FAQ, alsoIn).
const FR: Guide = {
  path: "/fr/partager-l-addition",
  lang: "fr",
  hreflang: "fr",
  locale: "fr_FR",
  languageName: "Français",
  title: "Partager l'addition au restaurant, plat par plat",
  description:
    "Partagez l'addition au plus juste : qui a pris quoi, plats et vin partagés, pourboire. Un exemple chiffré, et comment le faire en un instant sur iPhone.",
  eyebrow: "Guide",
  h1: "Comment partager l'addition au restaurant, plat par plat",
  lede: "Diviser l'addition en parts égales, c'est rapide, mais rarement juste&nbsp;: l'une a pris un croque-monsieur et une limonade, l'autre une entrecôte et la moitié d'une bouteille de vin. Partager plat par plat, c'est payer ce que l'on a commandé, plus sa juste part des plats partagés et du pourboire éventuel. Voici comment faire à la main, avec un exemple chiffré, et comment le faire en quelques gestes.",
  body: `
    <section>
      <h2>Quand partager plat par plat</h2>
      <p>Partagez en parts égales quand tout le monde a commandé à peu près la même chose, ou quand l'écart se résume à un café. Partagez plat par plat quand les commandes sont très différentes&nbsp;: quelqu'un ne boit pas d'alcool, quelqu'un n'a pris qu'une entrée, quelqu'un est arrivé pour le dessert. C'est surtout utile avec les amis avec qui vous dînez chaque semaine, parce que les petites injustices finissent par s'additionner. Et c'est indispensable quand une seule personne règle l'addition pour toute la table.</p>
    </section>

    <section>
      <h2>Étape par étape</h2>
      <ol class="howto">
        <li><strong>Parcourez l'addition ligne par ligne.</strong> À côté de chaque plat ou boisson, notez qui l'a pris.</li>
        <li><strong>Divisez ce qui a été partagé.</strong> Une pizza pour la table ou une bouteille de vin se divise entre ceux qui en ont vraiment profité, pas entre toute la table.</li>
        <li><strong>Additionnez la part de chacun.</strong> C'est son sous-total. Tous les sous-totaux réunis donnent le montant de l'addition avant pourboire.</li>
        <li><strong>Répartissez le pourboire au prorata.</strong> Qui a commandé 40&nbsp;% de l'addition laisse 40&nbsp;% du pourboire. Le plus simple&nbsp;: pour un pourboire de 5&nbsp;%, ajoutez 5&nbsp;% au sous-total de chacun.</li>
        <li><strong>Vérifiez le total.</strong> Les parts de tous doivent donner exactement la somme payée. S'il reste un centime après l'arrondi, attribuez-le à une personne.</li>
        <li><strong>Remboursez.</strong> Celui qui a réglé l'addition est remboursé par les autres, chacun pour sa part.</li>
      </ol>
    </section>

    <section>
      <h2>Un exemple chiffré</h2>
      <p>Léa, Hugo et Chloé ont dîné ensemble. Sur l'addition&nbsp;:</p>
      <div class="table-wrap"><table>
        <thead><tr><th>Plat</th><th class="num">Prix</th><th>Pour qui</th></tr></thead>
        <tbody>
          <tr><td>Planche mixte</td><td class="num">18,00&nbsp;€</td><td>Léa, Hugo, Chloé</td></tr>
          <tr><td>Bouteille de côtes-du-rhône</td><td class="num">30,00&nbsp;€</td><td>Léa, Hugo</td></tr>
          <tr><td>Salade de chèvre chaud</td><td class="num">14,00&nbsp;€</td><td>Léa</td></tr>
          <tr><td>Entrecôte frites</td><td class="num">24,00&nbsp;€</td><td>Hugo</td></tr>
          <tr><td>Croque-monsieur</td><td class="num">12,00&nbsp;€</td><td>Chloé</td></tr>
          <tr><td>Limonade</td><td class="num">4,00&nbsp;€</td><td>Chloé</td></tr>
          <tr class="total"><td>Total</td><td class="num">102,00&nbsp;€</td><td></td></tr>
        </tbody>
      </table></div>
      <p>En France, la TVA et le service sont déjà compris dans les prix&nbsp;: il n'y a rien à ajouter. La planche se partage à trois, soit 6,00&nbsp;€ chacun, et la bouteille à deux, puisque Chloé ne boit pas de vin, soit 15,00&nbsp;€ chacun pour Léa et Hugo. Ensuite&nbsp;:</p>
      <div class="table-wrap"><table>
        <thead><tr><th></th><th class="num">Sa commande</th><th class="num">Partagé</th><th class="num">Paie</th></tr></thead>
        <tbody>
          <tr><td>Léa</td><td class="num">14,00&nbsp;€</td><td class="num">21,00&nbsp;€</td><td class="num">35,00&nbsp;€</td></tr>
          <tr><td>Hugo</td><td class="num">24,00&nbsp;€</td><td class="num">21,00&nbsp;€</td><td class="num">45,00&nbsp;€</td></tr>
          <tr><td>Chloé</td><td class="num">16,00&nbsp;€</td><td class="num">6,00&nbsp;€</td><td class="num">22,00&nbsp;€</td></tr>
          <tr class="total"><td>Total</td><td class="num">54,00&nbsp;€</td><td class="num">48,00&nbsp;€</td><td class="num">102,00&nbsp;€</td></tr>
        </tbody>
      </table></div>
      <p>En parts égales, chacun aurait payé 34,00&nbsp;€&nbsp;: Chloé, qui n'a pas bu de vin, aurait payé 12,00&nbsp;€ de trop, tandis que Hugo aurait payé 11,00&nbsp;€ de moins que son repas, et Léa 1,00&nbsp;€ de moins.</p>
    </section>

    <section>
      <h2>Plats partagés, pourboire, TVA et remises</h2>
      <ul class="points">
        <li><strong>Les plats partagés</strong> se divisent seulement entre ceux qui en ont pris. Si deux personnes sur cinq ont partagé une bouteille de vin, elle se divise par deux.</li>
        <li><strong>Le pourboire</strong> est facultatif en France, puisque le service est compris dans les prix. Si vous en laissez un, le plus juste est de le partager au prorata&nbsp;: qui a commandé plus laisse plus. Un pourboire égal pour tous est plus simple, mais celui qui a commandé le moins laisse alors le plus gros pourcentage de sa commande.</li>
        <li><strong>La TVA</strong> est déjà incluse dans les prix en France et dans presque toute l'Europe, il n'y a donc rien à répartir. Si une taxe est ajoutée sur l'addition, comme aux États-Unis, répartissez-la au prorata, comme le pourboire.</li>
        <li><strong>Les remises</strong> vont à ceux dont les plats sont concernés. Une remise sur toute l'addition se répartit au prorata, comme le pourboire.</li>
      </ul>
    </section>

    <section>
      <h2>Partager l'addition en quelques gestes</h2>
      <p>Sur un coin de nappe, c'est possible, mais il faut dix minutes et une calculatrice. ${APP_NAME}, une application gratuite pour iPhone, le fait pour vous&nbsp;:</p>
      <div class="steps">
        <div class="step"><div>
          <h3>Scannez l'addition</h3>
          <p>Prenez en photo l'addition ou le ticket de caisse, ou choisissez une capture d'écran d'une commande en ligne. ${APP_NAME} lit chaque ligne, les prix et le total, y compris sur les tickets en français.</p>
        </div></div>
        <div class="step"><div>
          <h3>Indiquez qui a pris quoi</h3>
          <p>Attribuez chaque article à vos amis&nbsp;; ce qui a été partagé est divisé entre ceux qui l'ont partagé. Frais de service, suppléments et remises sont répartis au prorata automatiquement, et le pourboire aussi, dès que vous l'indiquez comme pourboire.</p>
        </div></div>
        <div class="step"><div>
          <h3>Faites les comptes</h3>
          <p>La part de chacun s'ajoute au solde que vous avez avec cet ami, compensé sur tous vos dîners et voyages. Marquez-la comme réglée quand l'argent est rendu.</p>
        </div></div>
      </div>
      <p class="note">Sans connexion à votre banque, sans création de compte et sans publicité. Vos données restent sur votre iPhone. L'application est pour l'instant en anglais.</p>
    </section>`,
  faqHeading: "Questions fréquentes",
  faq: [
    {
      q: "Faut-il partager le pourboire à parts égales ou selon la commande ?",
      a: "Selon la commande, au prorata du sous-total de chacun. Le pourboire est un pourcentage de l'addition, donc qui a commandé plus laisse plus. À parts égales, c'est acceptable quand tout le monde a commandé à peu près la même chose.",
    },
    {
      q: "Faut-il laisser un pourboire en France ?",
      a: "Ce n'est pas obligatoire : le service est compris dans les prix. Beaucoup de gens arrondissent l'addition ou laissent quelques euros quand le service était bon.",
    },
    {
      q: "Comment partager un plat commun ?",
      a: "Divisez son prix par le nombre de personnes qui en ont vraiment mangé, et ajoutez cette part au sous-total de chacune. Celui qui n'en a pas pris ne paie rien pour ce plat.",
    },
    {
      q: "Et si les plats ne correspondent pas au total de l'addition ?",
      a: "Cherchez sur l'addition des frais de service, une remise ou un supplément. Répartissez la différence au prorata des sous-totaux, comme le pourboire.",
    },
    {
      q: "Et si une seule personne a payé toute l'addition ?",
      a: "Chacun lui rembourse sa part. Si vous dînez souvent avec les mêmes amis, tenez plutôt un solde au lieu de rembourser à chaque fois : Non Bank le compense sur toutes vos additions partagées.",
    },
    {
      q: "Existe-t-il une application pour partager l'addition plat par plat ?",
      a: "Oui. Non Bank est une application gratuite pour iPhone : vous scannez l'addition, vous indiquez qui a pris quoi, et elle calcule la part de chacun, plats partagés et pourboire compris. Sans création de compte ni connexion à votre banque.",
    },
  ],
  cta: "Télécharger Non Bank gratuitement sur l'App Store",
  alsoIn: "Également en ",
  nav: { home: "Accueil", privacy: "Confidentialité", support: "Assistance" },
  published: "2026-11-24",
};

export const GUIDES: ReadonlyArray<Guide> = [EN, SR, RU, ES, DE, FR];

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const ALTERNATES = [
  ...GUIDES.map((g) => ({ hreflang: g.hreflang, path: g.path })),
  { hreflang: "x-default", path: EN.path },
];

function render(g: Guide): string {
  const canonical = SITE_URL + g.path;
  const article = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: g.h1,
    description: g.description,
    inLanguage: g.lang,
    datePublished: g.published,
    dateModified: g.published,
    mainEntityOfPage: canonical,
    image: `${SITE_URL}/og.png`,
    author: { "@type": "Organization", name: APP_NAME, url: SITE_URL + "/" },
    publisher: {
      "@type": "Organization",
      name: APP_NAME,
      logo: { "@type": "ImageObject", url: `${SITE_URL}/icon.png` },
    },
  };
  const faqLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    inLanguage: g.lang,
    mainEntity: g.faq.map((f) => ({
      "@type": "Question",
      name: f.q,
      acceptedAnswer: { "@type": "Answer", text: f.a },
    })),
  };
  const head = seoHead({
    path: g.path,
    title: g.title,
    description: g.description,
    locale: g.locale,
    ogType: "article",
    alternates: ALTERNATES,
    jsonLd: [article, faqLd],
  });
  const others = GUIDES.filter((o) => o !== g)
    .map((o) => `<a href="${o.path}" hreflang="${o.hreflang}" lang="${o.lang}">${o.languageName}</a>`)
    .join(" · ");
  const faqHtml = g.faq
    .map(
      (f) => `      <details>
        <summary>${esc(f.q)}</summary>
        <p>${esc(f.a)}</p>
      </details>`,
    )
    .join("\n");

  return `<!DOCTYPE html>
<html lang="${g.lang}">
<head>
${head}
<style>${STYLE}</style>
</head>
<body>
  <div class="page">
    <nav class="top"><a href="/">${APP_NAME}</a><span class="langs">${g.alsoIn}: ${others}</span></nav>
    <div class="eyebrow">${g.eyebrow}</div>
    <h1>${g.h1}</h1>
    <p class="lede">${g.lede}</p>
    <div class="cta-row">
      <a class="cta" href="${APP_STORE_URL}" rel="noopener">${g.cta}</a>
    </div>
${g.body}

    <section class="faq">
      <h2>${g.faqHeading}</h2>
${faqHtml}
    </section>

    <div class="cta-row end">
      <a class="cta" href="${APP_STORE_URL}" rel="noopener">${g.cta}</a>
    </div>

    <footer>
      ${APP_NAME} · <a href="/">${g.nav.home}</a> · <a href="/privacy">${g.nav.privacy}</a> · <a href="/support">${g.nav.support}</a> · <a href="${APP_STORE_URL}" rel="noopener">App Store</a> · <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
    </footer>
  </div>
</body>
</html>`;
}

// Same warm palette as the home page, plus article pieces: tables, lists.
const STYLE = `
  :root {
    color-scheme: dark light;
    --bg: #0a0807;
    --surface-elevated: #221c19;
    --text: #f4ede4;
    --text-secondary: #b8a695;
    --text-tertiary: #8a8076;
    --border: #2a2421;
    --accent: #c8afe1;
    --warm-cta: #c79566;
    --cta-bg: #97632c;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f7f3ee;
      --surface-elevated: #fbf6ef;
      --text: #1c1816;
      --text-secondary: #6b5d4f;
      --text-tertiary: #8a8076;
      --border: #efe7dc;
      --accent: #6E46B4;
      --warm-cta: #8a5520;
      --cta-bg: #8a5520;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    line-height: 1.6;
  }
  .page { max-width: 680px; margin: 0 auto; padding: 28px 22px 72px; }
  nav.top { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; font-size: 14px; margin-bottom: 44px; }
  nav.top > a { font-weight: 700; color: var(--text); }
  nav.top .langs { color: var(--text-tertiary); }
  .eyebrow { font-size: 13px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--accent); margin-bottom: 14px; }
  h1 { font-size: 34px; font-weight: 700; letter-spacing: -0.8px; line-height: 1.15; margin-bottom: 16px; }
  .lede { font-size: 18px; color: var(--text-secondary); margin-bottom: 28px; }
  .cta-row { display: flex; flex-wrap: wrap; gap: 12px; }
  .cta-row.end { margin-top: 40px; }
  .cta { display: inline-block; background: var(--cta-bg); color: #fff; font-size: 16px; font-weight: 600; padding: 13px 22px; border-radius: 12px; text-decoration: none; }
  .cta:hover { text-decoration: none; opacity: 0.92; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  section { margin-top: 48px; }
  section h2 { font-size: 22px; font-weight: 700; letter-spacing: -0.3px; margin-bottom: 14px; }
  section p { color: var(--text-secondary); margin-bottom: 12px; }
  strong { color: var(--text); }
  ol.howto, ul.points { padding-left: 22px; color: var(--text-secondary); }
  ol.howto li, ul.points li { margin-bottom: 10px; padding-left: 4px; }
  .table-wrap { overflow-x: auto; margin: 4px 0 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); }
  th { color: var(--text-tertiary); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }
  td { color: var(--text-secondary); }
  .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  tr.sub td, tr.total td { color: var(--text); font-weight: 600; }
  tr.total td { border-bottom: none; }
  .steps { counter-reset: step; display: grid; gap: 12px; margin-bottom: 14px; }
  .step { display: flex; gap: 14px; background: var(--surface-elevated); border: 1px solid var(--border); border-radius: 16px; padding: 16px 18px; }
  .step::before { counter-increment: step; content: counter(step); flex: 0 0 30px; height: 30px; border-radius: 50%; background: var(--cta-bg); color: #fff; font-weight: 700; display: flex; align-items: center; justify-content: center; font-size: 14px; }
  .step h3 { font-size: 15px; font-weight: 700; margin-bottom: 4px; }
  .step p { font-size: 14px; margin: 0; }
  .note { font-size: 14px; color: var(--text-tertiary); }
  .faq details { border-top: 1px solid var(--border); padding: 12px 0; }
  .faq details:last-child { border-bottom: 1px solid var(--border); }
  .faq summary { cursor: pointer; font-weight: 600; font-size: 15px; list-style: none; }
  .faq summary::-webkit-details-marker { display: none; }
  .faq summary::after { content: "+"; float: right; color: var(--text-tertiary); }
  .faq details[open] summary::after { content: "–"; }
  .faq p { font-size: 14px; margin: 8px 0 0; }
  footer { margin-top: 52px; padding-top: 24px; border-top: 1px solid var(--border); font-size: 13px; color: var(--text-tertiary); }
  footer a { color: var(--warm-cta); }
`;

const PAGES = new Map(GUIDES.map((g) => [g.path, render(g)]));

/** GET for a guide's path → the page; its path with a trailing slash → a
 *  301 to the canonical one; anything else → null. */
export function handleGuidePage(path: string): Response | null {
  const html = PAGES.get(path);
  if (html) {
    return new Response(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
  }
  if (path.length > 1 && path.endsWith("/") && PAGES.has(path.slice(0, -1))) {
    return new Response(null, { status: 301, headers: { Location: SITE_URL + path.slice(0, -1) } });
  }
  return null;
}
