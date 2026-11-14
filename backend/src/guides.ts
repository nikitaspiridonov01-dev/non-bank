// How-to guides on the public site, one per language, each written for a
// search with little competition that a new site can realistically rank for:
//
//   /split-receipt-by-item   "split a receipt by item"            (English)
//   /sr/podela-racuna        "podela računa"                      (Serbian, Latin)
//   /ru/kak-razdelit-schet   "как разделить счёт в ресторане"     (Russian)
//
// Each is a real answer, not a doorway page: when to split by item, the
// method step by step, a worked example whose numbers add up, shared dishes /
// tax / tip / discounts, an FAQ, and then the app. The three cover the same
// topic, so they name each other as hreflang alternates (English is the
// x-default). Claims about the app match what it does: shared items split
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
}

const PUBLISHED = "2026-11-14";

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
};

export const GUIDES: ReadonlyArray<Guide> = [EN, SR, RU];

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
    datePublished: PUBLISHED,
    dateModified: PUBLISHED,
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
