# Import Comic

## Introduction

VeneraNext can import comics from local directories, comic archives, PDF files,
and image-based EPUB files. Imported content is normalized into the existing
local image-comic layout so all reader modes, progress tracking, and split-spread
features continue to work.

Supported comic image extensions are `jpg`, `jpeg`, `jpe`, `png`, `webp`,
`gif`, and `avif`.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

VeneraNext supports importing comics from archive files.

Archive files are intended for import, export, backup, migration, and distribution. They must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, VeneraNext supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

An archive may contain images directly, or it may contain one top-level folder.
If the top-level folder contains chapter folders, VeneraNext imports those
folders as chapters.

```text
Cat's Eye.cbz
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

If there is no `cover.[ext]` in the root folder, the first image from the first
chapter is used as the cover.

## PDF and Image-based EPUB

Open `Local` -> `Import` and select either a PDF comic file or an image-based
EPUB file. Both formats are converted into app-managed local image comics during
import; the original document is not streamed by the reader.

### PDF

- Each PDF page is rendered to JPEG in order, and the first page is also used as the cover.
- The result is a flat comic without chapters. Its title defaults to the PDF file name.
- Pages are rendered at roughly three times their PDF point size with a 3000-pixel longest-edge limit to balance clarity, memory, and storage use.
- Encrypted or password-protected PDF files are not currently supported.
- Import creates a new image copy, so additional local storage is required.

### Image-based EPUB

- Fixed-layout EPUB files may use direct raster-image spine items or XHTML/SVG wrappers containing `img` or SVG `image` references.
- Page order follows the EPUB spine. Title, author, and cover metadata are preserved when available.
- Multiple valid navigation entries are preserved as chapters. Files without meaningful chapter navigation are imported as flat comics.
- Original raster images are copied without recompression.
- Text-based EPUB files, directly rendered SVG pages, external image references, and paths outside the EPUB root are rejected instead of silently dropping content.

MOBI, AZW, and AZW3 are not supported. Convert them externally to an image-based
EPUB, PDF, or CBZ before importing.

Document import never overwrites an existing comic with the same title.

## WebDAV Online Library

The WebDAV comic library is an online reading channel. It is separate from local import/export and WebDAV CBZ archive backup.

Online reading only reads images from remote directories. The app lists directories and loads images on demand; remote CBZ/ZIP/7Z files are not used for online preview. You can use a plain image directory or extract a single-comic CBZ exported by VeneraNext to WebDAV to preserve its title, author, tags, and chapters.

The **Sync comic library config** switch in WebDAV Comic Library settings is off by default. When enabled, DataSync/Appdata `.venera` files include the library URL, username, password, remote path, automatic-update switch, and update interval. The receiving device must also enable this switch locally before those fields are imported. Credentials are stored in the remote `.venera` file, so enable this only for trusted WebDAV storage and accounts.

### Plain Directory Mode

Recommended structure:

```text
/venera_comics/
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

Plain directory rules:

- The comic title defaults to the comic folder name.
- Child directories are chapters. Root-level images can also form a single-chapter comic.
- Pages and chapters are sorted by file name. Zero-padded names such as `0001.jpg` and `0002.jpg` are recommended.
- The preferred cover is a root image whose base name is `cover`. Supported extensions are `jpg`, `jpeg`, `png`, `webp`, `gif`, `jpe`, and `avif`. Without one, the app tries the first root page, then `cover.*` or the first page in the first readable chapter.
- Neither `metadata.json` nor `ComicInfo.xml` is required.

### Automatic Bangumi Scraping

After Bangumi is connected and **Automatic metadata scraping** is enabled in Settings (disabled by default), WebDAV library synchronization searches Bangumi for comics that do not have `metadata.json`. Before searching, the app removes explicitly labeled trailing author hints such as `Author: [Tsukasa Hojo]` or `作者：【北条司】`, plus known release annotations such as `语言：[Chinese]`, `版本[无修正]`, `[DL版]`, and `汉化者：[Group]`. Unknown unlabeled bracketed content remains part of the title. The cleaned title must exactly match the Bangumi Chinese or original title. If several subjects have the same title, the author hint must uniquely match the subject infobox or an author, original-creator, or artist relationship returned by the persons endpoint. Fuzzy or ambiguous results are not written.

On a successful match, the app creates a UTF-8 `metadata.json` with a create-only conditional request, so it cannot replace a file created concurrently by another client. The title uses Bangumi `name_cn`, falling back to `name`; the description uses the subject detail `summary`; authors come from the subject infobox or persons endpoint; tags combine all official `meta_tags` with the top 10 user tags ordered by descending `count`, then deduplicate the result. The WebDAV account must have write access. Automatic scraping never replaces an existing metadata file and does not download the Bangumi cover. Unmatched (`noMatch`) states are retained locally; the app does not re-query Bangumi during routine syncs, forced syncs, or file changes under the same scraper version, retrying only when the scraper version changes or when the user manually binds the subject. Transient network failures are retried after backoff.

When the user manually binds a Bangumi subject from comic details, that explicit selection is authoritative. A `bangumiSubjectId` already stored in `metadata.json` preselects that subject in the binding panel, but does not automatically bind it or create a Bangumi collection. Foreground loading ends as soon as binding succeeds; the app then reads subject details and updates `title`, `author`, `description`, `tags`, and `bangumiSubjectId` in the background. Empty selected values clear stale incorrect fields. Before updating, the app reads the latest metadata and uses its ETag or Last-Modified value as a write precondition; a concurrent conflict triggers a fresh read and merge. Valid `chapters` ranges and unknown extension fields are preserved. If the server supplies neither validator for an existing file, the unsafe overwrite is refused. Transient failures are stored locally with the library, comic, and subject identities, then retried at startup or after backoff. A changed configuration or binding invalidates the old task, and a background failure never undoes the successful progress binding.

Bangumi bindings are isolated by a normalized library identity made from the server URL, username, and remote root path. The password is deliberately excluded, so changing only a password retains bindings, while another server, account, or root cannot reuse bindings for matching relative paths. Selecting **Finished reading** refreshes both the remote collection and subject totals, then submits episode and volume progress together. Higher remote progress and higher values explicitly entered by the user are never reduced.

### Metadata-Marked Nested Layout

For a deeply nested WebDAV library, place `metadata.json` in the comic root to explicitly mark that directory as one comic:

```text
/venera_comics/
└── Category/
    └── Author/
        └── Cat's Eye/
            ├── metadata.json
            ├── cover.jpg
            ├── Chapter 01/
            │   ├── 001.jpg
            │   └── 002.jpg
            └── Chapter 02/
                └── 001.jpg
```

During WebDAV synchronization, the app recursively searches for directories containing `metadata.json` and treats each marked directory as one comic. Its direct child directories become chapters. Once a comic root is found, the app does not expose its chapters or deeper directories as separate comics. Comic IDs use paths relative to the configured WebDAV library path, so same-named comics in different categories do not overwrite one another.

In this mode, the title, author, description, and tags come from `metadata.json`, while chapter names and paths come from direct child directories. A root-level `cover.*` file is used only as the cover. Other root-level images are preserved in an `Images` chapter.

When real chapter directories and `metadata.json` page ranges coexist, the real directory layout takes precedence; page ranges are not matched to directories by position. `chapters[].start` and `chapters[].end` are used for virtual chapters only when the root contains flat images and no chapter directories, which preserves the extracted CBZ layout.

Synchronization performs bounded recursive discovery for unmarked nested libraries. A directory with ordinary root images is a comic. The WebDAV library determines comic boundaries using `metadata.json` and directory structure: `metadata.json` remains the strongest boundary with top priority, and child metadata is never bypassed by chapter naming heuristics. If a directory contains no root images and no metadata, it is recognized as a comic root when its direct leaf child directories match chapter naming conventions. When a category directly contains multiple flat single-volume comics (which are structurally isomorphic to a comic with multiple chapters), the app disambiguates them using chapter naming patterns so non-chapter subdirectories remain individual comics. In all modes, chapter directories are validated for readable comic pages: empty subdirectories or directories containing only a cover image are excluded from chapter lists and will never be selected as comic covers. If discovery encounters unrecoverable read errors or reaches safety limits (recursion depth or directory count), the sync operation fails closed and preserves the previous successful directory index without committing partial or speculative results. For complex or ambiguous hierarchies, placing `metadata.json` in each comic root is strongly recommended.

> If an older version mistakenly discovered chapter folders as individual comics and generated `metadata.json` files inside them, delete those erroneous chapter-level `metadata.json` files manually before resynchronizing; the app never deletes remote metadata files automatically.

### Extracted CBZ Enhanced Mode

A single-comic CBZ exported by VeneraNext normally has a flat image layout after extraction:

```text
/venera_comics/
└── Cat's Eye
    ├── metadata.json
    ├── ComicInfo.xml
    ├── cover.jpg
    ├── 0001.jpg
    ├── 0002.jpg
    ├── 0003.jpg
    └── 0004.jpg
```

`metadata.json` template:

```json
{
  "title": "Cat's Eye",
  "author": "Tsukasa Hojo",
  "description": "Three sisters run a café while searching for the truth about their missing father.",
  "tags": ["Action", "Manga"],
  "chapters": [
    {"title": "Volume 01", "start": 1, "end": 2},
    {"title": "Volume 02", "start": 3, "end": 4}
  ],
  "bangumiSubjectId": 123456
}
```

Field rules:

| Field | Type | Description |
|---|---|---|
| `title` | string | Comic title; an empty string falls back to the folder name |
| `author` | string | Author; may be empty |
| `description` | string | Comic description; may be empty; Bangumi scraping reads it from subject detail `summary` |
| `tags` | string array | Comic tags; may be empty |
| `bangumiSubjectId` | positive integer or `null` | Bangumi Subject ID written by automatic scraping or manual binding |
| `chapters` | array or `null` | Chapter ranges; root images form one chapter when this is `null` or empty |
| `chapters[].title` | string | Non-empty chapter display name |
| `chapters[].start` | integer | Inclusive first page, starting at 1 |
| `chapters[].end` | integer | Inclusive last page |

Chapter ranges must be ordered, non-overlapping, non-reversed, and within the actual number of root pages. `cover.*` is not included in page numbering. Extra metadata fields are allowed for forward compatibility. Remote URLs, scripts, and local absolute paths are not read from metadata.

`metadata.json` must use UTF-8; its file name is matched case-insensitively. `ComicInfo.xml` remains in the exported CBZ for compatibility with other readers, while the VeneraNext WebDAV library currently uses `metadata.json` as its enhanced metadata source.

When metadata is missing and Bangumi is connected, the app first attempts the conservative automatic match described above and otherwise falls back to plain directory mode. Automatic scraping does not replace an existing file that is unreadable, malformed, has invalid field types, or contains invalid chapter ranges; the comic remains visible using the parseable content or directory fallback. After an explicit Bangumi binding, a conditionally merged update can repair title, author, description, and tags when the file is still a parseable JSON object, while salvaging structurally valid `chapters`. An unparseable file is never silently replaced.

This `metadata.json` is the single-comic CBZ metadata format. It is not the comic-list format inside a `.venera-comics` batch export, and the two formats are not interchangeable.

### Archives and Online Reading

CBZ/ZIP/7Z files can still be uploaded, downloaded, and restored through WebDAV archive backup, but they are backup and distribution formats rather than online reading formats. Extract them on the WebDAV server for online reading; the app then reads images on demand without downloading the whole archive.
