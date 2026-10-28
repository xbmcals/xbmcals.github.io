/*
 * AnimeGate browser parser.
 *
 * Usage:
 *   await AnimeGateParser.run(26512)
 *
 * Copy JSON in Chrome/Edge DevTools:
 *   copy(JSON.stringify(await AnimeGateParser.run(26512), null, 2))
 *
 * Optional download:
 *   await AnimeGateParser.run(26512, { download: true })
 *
 * Browser JavaScript only. No Node.js required.
 */
(() => {
let result = ""

  const WORKER_URL =
    'https://odd-disk-9903.armin-apple816467.workers.dev/';

  const SEARCH_URL =
    'https://t.me/s/AnimeGateOfficial?q=';

  const CHANNEL_URL =
    'https://t.me/s/AnimeGateOfficial';

  const TG_AS_URL =
    'https://t.me/animegate_archive/';

  const TG_CLOUDFLARE_URL =
    'https://animegate-downloader.partifyc-3xa-9cd1a-ccp2l-pl.workers.dev/?id=';

  const PAGE_LIMIT = 52;
  const TYPE_IDS = { movie: 3 };
  const STATUS_IDS = { completed: 2 };

  const MD_LINK =
    /\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^)\s]+)\)/gu;

  function decodeEntities(text) {
    return String(text)
      .replace(/&nbsp;|&#160;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;|&apos;/gi, "'")
      .replace(/&#x([0-9a-f]+);/gi, (_, hex) =>
        String.fromCodePoint(parseInt(hex, 16))
      )
      .replace(/&#(\d+);/g, (_, num) =>
        String.fromCodePoint(parseInt(num, 10))
      );
  }

  function stripHtmlTags(text) {
    return decodeEntities(
      String(text).replace(/<[^>]*>/g, '')
    ).trim();
  }

  /**
   * Convert Telegram message HTML into Markdown-style text and links.
   */
  function htmlToMarkdown(input) {
    const source = String(input ?? '').replace(/\r\n?/g, '\n');

    const blockRegex =
      /<div\b[^>]*class=(['"])[^'"]*\btgme_widget_message_text\b[^'"]*\1[^>]*>([\s\S]*?)<\/div>/gi;

    const blocks = [...source.matchAll(blockRegex)];

    // Some proxies return text or Markdown instead of Telegram HTML.
    if (!blocks.length) return source;

    return blocks.map(match => {
      let body = match[2];

      body = body.replace(/<br\s*\/?>/gi, '\n');

      body = body.replace(
        /<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi,
        (_, doubleQuoted, singleQuoted, bare, label) => {
          let href = decodeEntities(
            doubleQuoted ?? singleQuoted ?? bare ?? ''
          );

          if (href.startsWith('?')) {
            href = CHANNEL_URL + href;
          }

          return `[${stripHtmlTags(label)}](${href})`;
        }
      );

      body = body.replace(
        /<\/(?:p|div|li|h\d)>/gi,
        '\n'
      );

      body = body.replace(/<[^>]*>/g, '');

      return decodeEntities(body)
        .replace(/[ \t]+\n/g, '\n')
        .trim();
    }).filter(Boolean).join('\n\n');
  }

  function normalizeText(text) {
    return String(text ?? '')
      .replace(/\\\\/g, '\\')
      .replace(/\r\n?/g, '\n')
      .replace(/\\[ \t]*\n/g, '\n')
      .trim();
  }

  function toLatinDigits(value) {
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';

    return String(value ?? '').replace(/[۰-۹٠-٩]/g, ch => {
      const p = persian.indexOf(ch);
      if (p !== -1) return String(p);

      const a = arabic.indexOf(ch);
      return a !== -1 ? String(a) : ch;
    });
  }

  function escapeRegExp(value) {
    return String(value).replace(
      /[.*+?^${}()|[\]\\]/g,
      '\\$&'
    );
  }

  function plain(value) {
    if (value == null) return null;

    MD_LINK.lastIndex = 0;

    const result = String(value)
      .replace(MD_LINK, '$1')
      .replace(/[*_`]/g, '')
      .replace(/[ \t]+/g, ' ')
      .trim();

    return result === '' ? null : result;
  }

  function mdLinks(value) {
    if (!value) return [];

    const links = [];
    MD_LINK.lastIndex = 0;

    let match;

    while ((match = MD_LINK.exec(String(value))) !== null) {
      links.push({
        text: match[1].trim(),
        url: match[2]
      });
    }

    return links;
  }

  function field(text, label) {
    const re = new RegExp(
      '^[\\t ]*(?:\\*{1,3})?[\\t ]*' +
      escapeRegExp(label) +
      '[\\t ]*:[\\t ]*(.*)$',
      'mu'
    );

    const match = String(text).match(re);
    return match ? match[1].trim() || null : null;
  }

  function linkInfo(value) {
    const links = mdLinks(value);
    const url = links.length ? links[0].url : null;

    let key = null;

    if (url) {
      try {
        const path = new URL(url).pathname.replace(/\/+$/, '');
        key = path.split('/').pop() || null;
      } catch {
        key = null;
      }
    }

    return {
      text: plain(value),
      url,
      key
    };
  }

  function parseScore(value) {
    if (value == null) return null;

    const match = toLatinDigits(value).match(
      /^\s*(\d+(?:\.\d+)?)/
    );

    return match ? Number(match[1]) : null;
  }

  /**
   * Rewrite Telegram archive links to the download API.
   */
  function rewriteDownloadUrl(url) {
    if (typeof url !== 'string') return url;

    if (url.startsWith(TG_AS_URL)) {
      return TG_CLOUDFLARE_URL + url.slice(TG_AS_URL.length);
    }

    return url;
  }

  function parseHeader(text) {
  const source = normalizeText(text);

  // Find the actual AnimeGate anime-page link, not the poster link.
  const titleLinkRegex =
    /\[([^\]\n]*)\]\((https:\/\/animegate\.net\/anime\/[^)\s]+)\)/gu;

  let titleMatch = null;
  let match;

  while ((match = titleLinkRegex.exec(source)) !== null) {
    const idMatch = match[2].match(/-(\d+)$/u);

    if (idMatch) {
      titleMatch = {
        label: match[1],
        url: match[2],
        id: Number(idMatch[1])
      };
      break;
    }
  }

  if (!titleMatch) {
    throw new Error(
      'Could not find a valid AnimeGate anime title link and ID.'
    );
  }

  // Find the poster image URL separately.
  const links = mdLinks(source);

  const imageLink = links.find(({ url }) => {
    try {
      const parsed = new URL(url);

      return (
        parsed.protocol === 'https:' &&
        parsed.hostname === 'animegate.net' &&
        (
          parsed.pathname.includes('/storage/anime/large-images/') ||
          /\.(?:avif|gif|jpe?g|png|webp)$/iu.test(parsed.pathname)
        )
      );
    } catch {
      return false;
    }
  });

  const title = titleMatch.label
    .replace(
      /^\s*دانلود\s+(?:(?:انیمه|انیمیشن|فیلم|سریال|دونگهوا)\s+)?/u,
      ''
    )
    .trim();

  return {
    title,
    url: titleMatch.url,
    id: titleMatch.id,
    image: imageLink?.url ?? null
  };
}
  /**
   * Extract episodes and their quality links.
   *
   * Example:
   * EP 01: [480P](...) | [720P](...) | [1080P](...)
   */
  function parseEpisodes(text) {
    const episodes = {};
    const lines = String(text).split('\n');

    for (const line of lines) {
      const match = line.match(
        /\b(EP\s*[\d٠-٩۰-۹]+(?:\.\d+)?)\s*:\s*(.*)$/iu
      );

      if (!match) continue;

      const episodeLabel = match[1]
        .replace(/\s+/gu, ' ')
        .trim();

      const labelLinks = mdLinks(match[2]);

      for (const link of labelLinks) {
        const qualityLabel = link.text
          .replace(/\s+/gu, ' ')
          .trim();

        episodes[episodeLabel] ??= {};

        episodes[episodeLabel][qualityLabel] =
          rewriteDownloadUrl(link.url);
      }
    }

    return episodes;
  }

  function episodeNumber(label, fallback) {
    const match = toLatinDigits(label).match(
      /(\d+(?:\.\d+)?)/u
    );

    if (!match) return fallback;

    return match[1].includes('.')
      ? Number(match[1])
      : Number.parseInt(match[1], 10);
  }

  function episodeLineStarts(line) {
    return /\bEP\s*[\d٠-٩۰-۹]+(?:\.\d+)?\s*:/iu.test(line);
  }

  function postIdFromUrl(url) {
    try {
      const path = new URL(url).pathname.replace(/\/+$/, '');
      const match = path.match(/-(\d+)$/u);

      return match ? Number(match[1]) : null;
    } catch {
      return null;
    }
  }

  /**
   * Split the Telegram search page into posts and keep exact anime-ID matches.
   */
  function extractMatchingPosts(responseBody, id) {
    const text = normalizeText(
      htmlToMarkdown(responseBody)
    );

    const headerRegex =
      /^\[([^\n]*?)\]\((https:\/\/animegate\.net\/anime\/[^)\s]+)\)/gmu;

    const headers = [...text.matchAll(headerRegex)];

    if (!headers.length) {
      // Handle a proxy response containing just one isolated post.
      const single = text.match(
        /^\[[^\n]*?\]\((https:\/\/animegate\.net\/anime\/[^)\s]+)\)/mu
      );

      if (single && postIdFromUrl(single[1]) === Number(id)) {
        return [text];
      }

      throw new Error(
        'Could not find AnimeGate title links in the proxy response. ' +
        'The proxy may not have returned Telegram post HTML.'
      );
    }

    const posts = [];

    for (let i = 0; i < headers.length; i++) {
      const current = headers[i];

      if (postIdFromUrl(current[2]) !== Number(id)) {
        continue;
      }

      const start = current.index;
      const end =
        i + 1 < headers.length
          ? headers[i + 1].index
          : text.length;

      const post = text.slice(start, end).trim();

      if (post) posts.push(post);
    }

    if (!posts.length) {
      throw new Error(
        `No Telegram posts found for anime ID ${id}.`
      );
    }

    return posts;
  }

  /**
   * Merge episode/quality links across matching posts.
   *
   * The first matching post supplies the main metadata.
   * Later posts can contribute additional episode qualities.
   * If the same episode/quality appears more than once,
   * the later occurrence wins.
   */
  function mergeMatchingPosts(posts) {
    if (!Array.isArray(posts) || posts.length === 0) {
      throw new Error(
        'No matching anime posts were available to merge.'
      );
    }

    if (posts.length === 1) {
      return normalizeText(posts[0]);
    }

    const baseLines = normalizeText(posts[0]).split('\n');

    const metadata = baseLines
      .filter(line => !episodeLineStarts(line))
      .join('\n')
      .trim();

    const merged = new Map();

    for (const post of posts) {
      const episodes = parseEpisodes(post);

      for (const [episode, variants] of Object.entries(episodes)) {
        if (!merged.has(episode)) {
          merged.set(episode, new Map());
        }

        const byQuality = merged.get(episode);

        for (const [quality, url] of Object.entries(variants)) {
          byQuality.set(quality, url);
        }
      }
    }

    const episodeLines = [...merged.entries()]
      .sort(([a], [b]) =>
        episodeNumber(a, 0) - episodeNumber(b, 0) ||
        a.localeCompare(
          b,
          undefined,
          { numeric: true, sensitivity: 'base' }
        )
      )
      .map(([episode, variants]) => {
        const links = [...variants.entries()]
          .sort(([a], [b]) => {
            const qa = Number(
              (a.match(/(\d{3,4})\s*p/iu) || [])[1] || 0
            );

            const qb = Number(
              (b.match(/(\d{3,4})\s*p/iu) || [])[1] || 0
            );

            if (qa !== qb) return qa - qb;

            const ha = /x265|hevc/iu.test(a) ? 1 : 0;
            const hb = /x265|hevc/iu.test(b) ? 1 : 0;

            return (
              ha - hb ||
              a.localeCompare(
                b,
                undefined,
                { numeric: true, sensitivity: 'base' }
              )
            );
          })
          .map(([quality, url]) => `[${quality}](${url})`);

        return `⛩ ${episode}: ${links.join(' | ')}`;
      });

    return [metadata, ...episodeLines]
      .filter(Boolean)
      .join('\n\n');
  }

  function qualityOf(label) {
    const match = String(label).match(/(\d{3,4})\s*p/iu);
    return match ? Number(match[1]) : null;
  }

  function isHevc(label) {
    return /x265|hevc/iu.test(String(label)) ? 1 : 0;
  }

  function episodeDisplayLabel(key, number) {
    return /^(?:ep(?:isode)?\.?\s*)?\d+(?:\.\d+)?$/iu.test(key)
      ? `قسمت: ${number}`
      : key;
  }

  /**
   * Build the AnimeGate-style response object.
   */
  function buildPayload(rawText) {
    const text = normalizeText(rawText);
    const header = parseHeader(text);

    const type = linkInfo(field(text, 'نوع'));
    const status = linkInfo(field(text, 'وضعیت'));
    const season = linkInfo(field(text, 'فصل'));
    const source = linkInfo(field(text, 'منبع'));

    const airedRaw = field(text, 'پخش از');
    const yearField = field(text, 'سال ساخت میلادی');

    let year = null;
    let yearOriginal = null;

    for (const link of mdLinks(airedRaw)) {
      const match = link.url.match(
        /\/anime\/year\/(\d{4})$/u
      );

      if (match) {
        const visibleYear = toLatinDigits(link.text)
          .match(/\d{4}/u);

        year = visibleYear ? Number(visibleYear[0]) : null;
        yearOriginal = Number(match[1]);
        break;
      }
    }

    if (yearOriginal == null && yearField != null) {
      const parsedYear = toLatinDigits(yearField)
        .match(/\d{4}/u);

      yearOriginal = parsedYear
        ? Number(parsedYear[0])
        : null;
    }

    const genres = mdLinks(field(text, 'ژانرها')).map(link => ({
      id: null,
      title: link.text.replace(/^#/, '').trim()
    }));

    const translators = [];
    const teamText = plain(field(text, 'مرجع زیرنویس'));

    if (teamText) {
      for (const name of teamText.split(/\s*[,،]\s*/u)) {
        if (name.trim()) {
          translators.push(name.trim());
        }
      }
    }

    const parsedEpisodes = parseEpisodes(text);

    const episodeKeys = Object.keys(parsedEpisodes).sort(
      (a, b) => String(a).localeCompare(
        String(b),
        undefined,
        { numeric: true, sensitivity: 'base' }
      )
    );

    const groups = new Map();
    let lastEpisode = null;

    episodeKeys.forEach((key, index) => {
      const es = episodeNumber(key, index + 1);

      if (lastEpisode === null || es > lastEpisode) {
        lastEpisode = es;
      }

      for (const [label, url] of Object.entries(parsedEpisodes[key])) {
        if (!groups.has(label)) {
          groups.set(label, []);
        }

        groups.get(label).push({
          label: episodeDisplayLabel(key, es),
          es,
          link: url,
          online: true,
          is_free: true,
          filler: null
        });
      }
    });

    const orderedGroups = [...groups.entries()].sort(
      ([a], [b]) => {
        const q = (qualityOf(a) ?? 0) - (qualityOf(b) ?? 0);

        if (q !== 0) return q;

        const hevc = isHevc(a) - isHevc(b);

        return hevc !== 0
          ? hevc
          : a.localeCompare(
              b,
              undefined,
              { numeric: true, sensitivity: 'base' }
            );
      }
    );

    const seriesLinks = orderedGroups.map(([label, data]) => ({
      id: null,
      quality: qualityOf(label),
      type: 1,
      label: `${label} هاردساب`,
      links: {
        data,
        paginator: {
          total_count: data.length,
          total_pages: 1,
          current_page: 1,
          limit: Math.max(PAGE_LIMIT, data.length)
        }
      },
      field: 'link_series'
    }));

    seriesLinks.push({
      field: 'link_translation_team',
      items: translators.map(trans => ({
        trans,
        link: null
      }))
    });

    const bestQuality = orderedGroups.reduce(
      (best, [label]) =>
        Math.max(best, qualityOf(label) || 0),
      0
    );

    const premiered = season.text;

    const seasonYearMatch = premiered
      ? toLatinDigits(premiered).match(/\d{4}/u)
      : null;

    const postScore = parseScore(
      field(text, 'انیمه گیت')
    );

    const score = parseScore(
      field(text, 'مای انیمه لیست')
    );

    const episodeCount = plain(
      field(text, 'تعداد قسمت')
    );

    const anime = {
      id: header.id,
      url: header.url,
      title: header.title,

      title_english: plain(field(text, 'نام انگلیسی')),
      title_fa: plain(field(text, 'نام فارسی')),
      title_jp: plain(field(text, 'نام ژاپنی')),
      title_synonyms: [],

      type_id: Object.prototype.hasOwnProperty.call(
        TYPE_IDS,
        type.key
      ) ? TYPE_IDS[type.key] : null,

      type: type.text,
      type_key: type.key,

      language: null,
      language_label: null,

      year_original: yearOriginal,
      year,

      is_subtited: true,
      is_uploaded: orderedGroups.length > 0,
      is_music: false,

      best_quality: bestQuality > 0
        ? `${bestQuality}P`
        : null,

      post_hint: null,

      trailers: [],
      musicVideos: [],
      themes: [],
      pictures: [],
      blogs: [],

      helpDownloadLinks: [{
        title: 'دانلودر ورکر کلادفلر',
        is_sharing: false,
        is_http: false,
        convert: [{
          as_url: TG_AS_URL,
          to_url: TG_CLOUDFLARE_URL
        }]
      }],

      down_message: null,
      links: seriesLinks,

      status_key: status.key,

      status_id: Object.prototype.hasOwnProperty.call(
        STATUS_IDS,
        status.key
      ) ? STATUS_IDS[status.key] : null,

      status: status.text,
      last_update: lastEpisode === null
        ? null
        : String(lastEpisode),

      synopsis: null,
      image: header.image,

      episodes: episodeCount ?? String(episodeKeys.length),

      canScore: true,
      score,
      score_count: null,

      post_score: postScore,
      post_score_count: null,

      premiered,

      season_year: seasonYearMatch
        ? Number(seasonYearMatch[0])
        : false,

      aired_string: plain(airedRaw),
      broadcast: 'نامشخص',
      duration: plain(field(text, 'زمان هر قسمت')),
      rating: plain(field(text, 'رده סنی')),

      source: source.text,
      source_key: source.key,

      producer_items: [],
      studio: [],
      genres,
      parental: null
    };

    return {
      item: {
        anime,

        animeDataUser: {
          id: null,
          name: null,
          anime_id: header.id,
          download: '',
          episode: '',
          list: false,
          rating: '',
          status: '',
          user_id: null
        },

        related: [],
        relateds: [],
        infoRelated: [],

        userHasShare: false,
        schedule: { status: false },

        comment: {
          count: 0,
          status: true,
          message: '',
          type: ''
        },

        comment_count: 0,
        manhwa: null
      },

      status_code: 200
    };
  }

  /**
   * Fetch Telegram search results through the Cloudflare Worker.
   */
  async function fetchAnimePosts(id) {
    const animeId = String(id ?? '').trim();

    if (!/^\d+$/u.test(animeId)) {
      throw new Error(
        'Missing or invalid anime ID. Example: ' +
        'await AnimeGateParser.run(26512)'
      );
    }

    const targetUrl = SEARCH_URL + encodeURIComponent(animeId);
    const proxyUrl = new URL(WORKER_URL);

    proxyUrl.searchParams.set('url', targetUrl);

    const controller = new AbortController();

    const timeoutId = setTimeout(
      () => controller.abort(),
      30000
    );

    try {
      const response = await fetch(proxyUrl.toString(), {
        method: 'GET',
        mode: 'cors',
        credentials: 'omit',

        headers: {
          Accept: 'text/html, text/plain;q=0.9, */*;q=0.8'
        },

        signal: controller.signal
      });

      if (!response.ok) {
        throw new Error(
          `Proxy request failed with HTTP ${response.status}`
        );
      }

      return await response.text();

    } catch (error) {
      if (error && error.name === 'AbortError') {
        throw new Error(
          'Proxy request timed out after 30 seconds.'
        );
      }

      if (error instanceof TypeError) {
        throw new Error(
          'Browser could not fetch the Worker. Check the Worker URL, ' +
          'network access, and CORS headers (Access-Control-Allow-Origin).'
        );
      }

      throw error;

    } finally {
      clearTimeout(timeoutId);
    }
  }

  /**
   * Main parser API.
   */
  async function api(id) {
    try {
      const responseBody = await fetchAnimePosts(id);
      const posts = extractMatchingPosts(responseBody, id);
      const mergedPost = mergeMatchingPosts(posts);

      return buildPayload(mergedPost);

    } catch (error) {
      const message = error instanceof Error
        ? error.message
        : String(error);

      const status =
        /No Telegram posts found|Could not find AnimeGate title links/u
          .test(message)
          ? 404
          : 502;

      return {
        status_code: status,
        message
      };
    }
  }

  /**
   * Optional file download.
   * Not used by default when running AnimeGateParser.run().
   */
  function downloadJson(payload, filename) {
    const blob = new Blob(
      [JSON.stringify(payload, null, 2) + '\n'],
      { type: 'application/json;charset=utf-8' }
    );

    const objectUrl = URL.createObjectURL(blob);
    const anchor = document.createElement('a');

    anchor.href = objectUrl;
    anchor.download = filename || 'animegate.json';
    anchor.style.display = 'none';

    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();

    setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
  }

  /**
   * Run without downloading unless { download: true } is specified.
   */
  async function run(id, options = {}) {
    const payload = await api(id);


    // Display the full JSON as text in the browser console.

    // Optional download only when explicitly requested.

    return {data: payload};
  }

  // Public browser API.
  window.AnimeGateParser = Object.freeze({
    api,
    run,
    downloadJson,
    buildPayload,
    extractMatchingPosts,
    fetchAnimePosts,
    htmlToMarkdown,
    mergeMatchingPosts,
    parseEpisodes,
    rewriteDownloadUrl
  });

})();