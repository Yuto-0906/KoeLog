#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const NOTION_VERSION = process.env.NOTION_VERSION || "2026-03-11";
const README_PATH = process.env.README_PATH || "README.md";
const NOTION_CODE_LANGUAGES = new Set([
  "abap",
  "arduino",
  "bash",
  "basic",
  "c",
  "clojure",
  "coffeescript",
  "c++",
  "c#",
  "css",
  "dart",
  "diff",
  "docker",
  "elixir",
  "elm",
  "erlang",
  "flow",
  "fortran",
  "f#",
  "gherkin",
  "glsl",
  "go",
  "graphql",
  "groovy",
  "haskell",
  "html",
  "java",
  "javascript",
  "json",
  "julia",
  "kotlin",
  "latex",
  "less",
  "lisp",
  "livescript",
  "lua",
  "makefile",
  "markdown",
  "markup",
  "matlab",
  "mermaid",
  "nix",
  "objective-c",
  "ocaml",
  "pascal",
  "perl",
  "php",
  "plain text",
  "powershell",
  "prolog",
  "protobuf",
  "python",
  "r",
  "reason",
  "ruby",
  "rust",
  "sass",
  "scala",
  "scheme",
  "scss",
  "shell",
  "sql",
  "swift",
  "typescript",
  "vb.net",
  "verilog",
  "vhdl",
  "visual basic",
  "webassembly",
  "xml",
  "yaml",
  "java/c/c++/c#",
]);
const notionToken = process.env.NOTION_TOKEN || process.env.NOTION_API_KEY;
const notionPageId = normalizeNotionId(
  process.env.NOTION_PAGE_ID || process.env.NOTION_TARGET_PAGE_ID,
);

if (!notionToken) {
  throw new Error("NOTION_TOKEN or NOTION_API_KEY is required.");
}

if (!notionPageId) {
  throw new Error("NOTION_PAGE_ID or NOTION_TARGET_PAGE_ID is required.");
}

const sourceUrl = buildSourceUrl();
const markdown = await readFile(README_PATH, "utf8");
const blocks = [
  textBlock(
    "paragraph",
    sourceUrl
      ? `Synced automatically from ${sourceUrl}`
      : `Synced automatically from ${README_PATH}`,
  ),
  ...markdownToBlocks(markdown),
];

if (process.env.DRY_RUN === "1") {
  console.log(`Dry run: parsed ${blocks.length} Notion blocks from ${README_PATH}.`);
  process.exit(0);
}

await replacePageChildren(notionPageId, blocks);
console.log(`Synced ${blocks.length} Notion blocks from ${README_PATH}.`);

async function replacePageChildren(pageId, nextBlocks) {
  const existingBlocks = await listChildren(pageId);

  for (const block of existingBlocks) {
    await notionRequest(`/blocks/${block.id}`, {
      method: "PATCH",
      body: { in_trash: true },
    });
  }

  for (const chunk of chunkArray(nextBlocks, 100)) {
    await notionRequest(`/blocks/${pageId}/children`, {
      method: "PATCH",
      body: { children: chunk },
    });
  }
}

async function listChildren(blockId) {
  const results = [];
  let cursor;

  do {
    const query = new URLSearchParams({ page_size: "100" });
    if (cursor) query.set("start_cursor", cursor);

    const response = await notionRequest(
      `/blocks/${blockId}/children?${query.toString()}`,
    );

    results.push(...response.results);
    cursor = response.has_more ? response.next_cursor : undefined;
  } while (cursor);

  return results;
}

async function notionRequest(path, options = {}) {
  const { method = "GET", body } = options;
  const response = await requestWithRetry(`https://api.notion.com/v1${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${notionToken}`,
      "Content-Type": "application/json",
      "Notion-Version": NOTION_VERSION,
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : {};

  if (!response.ok) {
    const message = data.message || response.statusText;
    throw new Error(`Notion API ${response.status}: ${message}`);
  }

  return data;
}

async function requestWithRetry(url, options, attempt = 0) {
  const response = await fetch(url, options);

  if (response.status !== 429 && response.status < 500) {
    return response;
  }

  if (attempt >= 5) {
    return response;
  }

  const retryAfter = Number(response.headers.get("retry-after"));
  const delayMs = Number.isFinite(retryAfter)
    ? retryAfter * 1000
    : 1000 * 2 ** attempt;

  await new Promise((resolve) => setTimeout(resolve, delayMs));
  return requestWithRetry(url, options, attempt + 1);
}

function markdownToBlocks(markdownText) {
  const lines = markdownText.replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let paragraph = [];
  let codeFence;

  const flushParagraph = () => {
    const text = paragraph.join(" ").trim();
    paragraph = [];
    if (text) {
      blocks.push(...textBlocks("paragraph", text));
    }
  };

  for (const line of lines) {
    const fenceMatch = line.match(/^```([^`]*)\s*$/);

    if (codeFence) {
      if (fenceMatch) {
        blocks.push(codeBlock(codeFence.lines.join("\n"), codeFence.language));
        codeFence = undefined;
      } else {
        codeFence.lines.push(line);
      }
      continue;
    }

    if (fenceMatch) {
      flushParagraph();
      codeFence = {
        language: normalizeCodeLanguage(fenceMatch[1]),
        lines: [],
      };
      continue;
    }

    if (!line.trim()) {
      flushParagraph();
      continue;
    }

    const headingMatch = line.match(/^(#{1,4})\s+(.+)$/);
    if (headingMatch) {
      flushParagraph();
      const level = headingMatch[1].length;
      blocks.push(...textBlocks(`heading_${level}`, headingMatch[2].trim()));
      continue;
    }

    if (/^(-{3,}|\*{3,}|_{3,})\s*$/.test(line.trim())) {
      flushParagraph();
      blocks.push({ type: "divider", divider: {} });
      continue;
    }

    const imageMatch = line.match(/^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$/);
    if (imageMatch) {
      flushParagraph();
      blocks.push(imageBlock(imageMatch[2], imageMatch[1]));
      continue;
    }

    const todoMatch = line.match(/^\s*[-*+]\s+\[([ xX])\]\s+(.+)$/);
    if (todoMatch) {
      flushParagraph();
      blocks.push(
        textBlock("to_do", todoMatch[2].trim(), {
          checked: todoMatch[1].toLowerCase() === "x",
        }),
      );
      continue;
    }

    const bulletMatch = line.match(/^\s*[-*+]\s+(.+)$/);
    if (bulletMatch) {
      flushParagraph();
      blocks.push(textBlock("bulleted_list_item", bulletMatch[1].trim()));
      continue;
    }

    const numberedMatch = line.match(/^\s*\d+\.\s+(.+)$/);
    if (numberedMatch) {
      flushParagraph();
      blocks.push(textBlock("numbered_list_item", numberedMatch[1].trim()));
      continue;
    }

    const quoteMatch = line.match(/^>\s?(.+)$/);
    if (quoteMatch) {
      flushParagraph();
      blocks.push(textBlock("quote", quoteMatch[1].trim()));
      continue;
    }

    paragraph.push(line.trim());
  }

  if (codeFence) {
    blocks.push(codeBlock(codeFence.lines.join("\n"), codeFence.language));
  }

  flushParagraph();
  return blocks;
}

function textBlocks(type, text) {
  const chunks = splitText(text, 1800);
  return chunks.map((chunk, index) => {
    if (index === 0) {
      return textBlock(type, chunk);
    }
    return textBlock("paragraph", chunk);
  });
}

function textBlock(type, text, extra = {}) {
  const richText = richTextFromMarkdown(text);
  return {
    type,
    [type]: {
      rich_text: richText.length ? richText : [{ type: "text", text: { content: "" } }],
      color: "default",
      ...extra,
    },
  };
}

function codeBlock(text, language) {
  return {
    type: "code",
    code: {
      caption: [],
      rich_text: splitText(text || " ", 1900).map((content) => ({
        type: "text",
        text: { content },
      })),
      language,
    },
  };
}

function imageBlock(url, altText) {
  const resolvedUrl = resolveAssetUrl(url);
  return {
    type: "image",
    image: {
      type: "external",
      external: { url: resolvedUrl },
      caption: altText ? plainRichText(altText) : [],
    },
  };
}

function richTextFromMarkdown(text) {
  const richText = [];
  const tokenPattern =
    /(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*\n]+\*|_[^_\n]+_|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|https?:\/\/[^\s)]+)/g;
  let lastIndex = 0;
  let match;

  while ((match = tokenPattern.exec(text))) {
    pushRichText(richText, text.slice(lastIndex, match.index));

    const token = match[0];
    if (token.startsWith("`")) {
      pushRichText(richText, token.slice(1, -1), { code: true });
    } else if (token.startsWith("**") || token.startsWith("__")) {
      pushRichText(richText, token.slice(2, -2), { bold: true });
    } else if (token.startsWith("*") || token.startsWith("_")) {
      pushRichText(richText, token.slice(1, -1), { italic: true });
    } else if (match[2]) {
      pushRichText(richText, match[2], {}, resolveAssetUrl(match[3]));
    } else if (/^https?:\/\//.test(token)) {
      pushRichText(richText, token, {}, token);
    }

    lastIndex = tokenPattern.lastIndex;
  }

  pushRichText(richText, text.slice(lastIndex));
  return richText;
}

function plainRichText(text) {
  const richText = [];
  pushRichText(richText, text);
  return richText;
}

function pushRichText(richText, content, annotations = {}, href) {
  if (!content) return;

  for (const chunk of splitText(content, 1900)) {
    richText.push({
      type: "text",
      text: {
        content: chunk,
        ...(href ? { link: { url: href } } : {}),
      },
      annotations: {
        bold: false,
        italic: false,
        strikethrough: false,
        underline: false,
        code: false,
        color: "default",
        ...annotations,
      },
    });
  }
}

function splitText(text, maxLength) {
  if (text.length <= maxLength) {
    return [text];
  }

  const chunks = [];
  let remaining = text;

  while (remaining.length > maxLength) {
    let splitAt = remaining.lastIndexOf(" ", maxLength);
    if (splitAt < maxLength * 0.6) splitAt = maxLength;
    chunks.push(remaining.slice(0, splitAt).trimEnd());
    remaining = remaining.slice(splitAt).trimStart();
  }

  if (remaining) chunks.push(remaining);
  return chunks;
}

function chunkArray(items, size) {
  const chunks = [];
  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }
  return chunks;
}

function normalizeCodeLanguage(language) {
  const normalized = language.trim().toLowerCase();
  const aliases = {
    "": "plain text",
    js: "javascript",
    jsx: "javascript",
    ts: "typescript",
    tsx: "typescript",
    sh: "shell",
    zsh: "shell",
    yml: "yaml",
    md: "markdown",
    objectivec: "objective-c",
  };

  const candidate = aliases[normalized] || normalized || "plain text";
  return NOTION_CODE_LANGUAGES.has(candidate) ? candidate : "plain text";
}


function resolveAssetUrl(url) {
  if (/^https?:\/\//.test(url)) {
    return url;
  }

  const repository = process.env.GITHUB_REPOSITORY;
  const ref = process.env.GITHUB_SHA || process.env.GITHUB_REF_NAME || "main";

  if (!repository) {
    return url;
  }

  return `https://raw.githubusercontent.com/${repository}/${ref}/${url.replace(/^\.\//, "")}`;
}

function buildSourceUrl() {
  const serverUrl = process.env.GITHUB_SERVER_URL;
  const repository = process.env.GITHUB_REPOSITORY;
  const sha = process.env.GITHUB_SHA;

  if (!serverUrl || !repository || !sha) {
    return undefined;
  }

  return `${serverUrl}/${repository}/blob/${sha}/${README_PATH}`;
}

function normalizeNotionId(value) {
  if (!value) return undefined;

  const raw = String(value).trim();
  const compactMatch = raw.match(/[0-9a-fA-F]{32}/);
  if (compactMatch) {
    return hyphenateId(compactMatch[0]);
  }

  const uuidMatch = raw.match(
    /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/,
  );

  return uuidMatch ? uuidMatch[0] : raw;
}

function hyphenateId(id) {
  return `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(
    16,
    20,
  )}-${id.slice(20)}`;
}
