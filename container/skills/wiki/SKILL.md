# Wiki Skill

Operational instructions for maintaining a Karpathy-style LLM wiki.

## Directory Layout

```
/workspace/group/
  wiki/         # LLM-owned markdown pages
    index.md    # Content catalog — update on every ingest
    log.md      # Append-only operation log
    *.md        # Topic, entity, concept, summary pages
  sources/      # Immutable raw sources — never modify
```

## Operations

### Ingest

Triggered when the user drops a source (URL, file, PDF, image, voice note, paste).

**Process ONE source at a time — never batch:**

1. Read `wiki/index.md` and `wiki/log.md` to orient
2. Read/fetch the source fully:
   - URL (webpage): use `agent-browser` or fetch full text with bash: `curl -sL "<url>" | python3 -m html.parser` or save locally first: `curl -sLo sources/<name>.md "<url>"`
   - PDF: save to `sources/` then extract: `pdftotext sources/<name>.pdf -`
   - Image: read directly (multimodal)
   - Pasted text: treat as-is
3. Discuss key takeaways with the user
4. Create/update wiki pages — a single source typically touches 5–15 pages:
   - Summary page for the source itself
   - Entity pages (people, projects, tools, models, companies)
   - Concept pages (ideas, patterns, techniques)
   - Update any existing pages where this source adds/contradicts info
   - Flag contradictions with existing pages explicitly
5. Update `wiki/index.md` — add/update entries for every touched page
6. Append to `wiki/log.md`: `## [YYYY-MM-DD] ingest | <source title>`
7. Confirm completion before moving to the next source

### Query

Triggered when the user asks a question.

1. Read `wiki/index.md` to find relevant pages
2. Read those pages in full
3. Synthesize an answer with citations to wiki pages
4. If the answer is a useful artifact (comparison, synthesis, analysis), offer to save it as a new wiki page
5. If saved: update `wiki/index.md` and append to `wiki/log.md`: `## [YYYY-MM-DD] query | <question summary>`

### Lint

Triggered by `/lint` or scheduled task.

1. Read all wiki pages via `wiki/index.md`
2. Check for:
   - Contradictions between pages
   - Stale claims (superseded by newer sources)
   - Orphan pages (no inbound links from other pages)
   - Missing cross-references between related pages
   - Important concepts without dedicated pages
   - Data gaps worth investigating
3. Report findings grouped by severity
4. Offer to fix issues interactively
5. Append to `wiki/log.md`: `## [YYYY-MM-DD] lint | <summary>`

## Page Conventions

- Filename: lowercase, hyphens, `.md` extension (e.g. `esphome-climate-component.md`)
- Start each page with a `# Title` and one-line description
- Use `[[wikilink]]` style cross-references in text (write as markdown links: `[Page](page.md)`)
- Add YAML frontmatter for structured data when useful:
  ```yaml
  ---
  type: entity|concept|summary|synthesis
  sources: [source-title-1, source-title-2]
  updated: YYYY-MM-DD
  ---
  ```

## Source Handling Notes

- **Save sources locally** before processing when possible — avoids re-fetching
- **Full text matters** — use curl/download rather than WebFetch summaries for ingestion
- **Images**: read directly as multimodal input; save to `sources/images/`
- **PDFs**: require `pdftotext` — check availability with `which pdftotext`
