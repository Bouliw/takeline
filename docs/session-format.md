# Session files

At the end of each reading with word tracking, Takeline can save what happened: the script, sentence by sentence, every take of every sentence and every retake, timed. An editing tool reads it to keep the last good take of each sentence and cut the rest.

Saving is on by default and can be turned off in **Settings → Voice → Save sessions**, which also sets the folder (`~/Documents/Takeline` by default). Nothing is saved when no sentence was read.

## File

One JSON file per session, named after the script and the start time:

```
Bakery 2026-10-12 14.03.11.takeline.json
```

## Example

```json
{
  "app" : "Takeline 1.0",
  "ended_at" : "2026-10-12T12:06:02Z",
  "format" : "takeline.session",
  "languages" : [ "fr" ],
  "retakes" : [
    {
      "phrase" : "on la refait",
      "sentence" : 5,
      "time" : 54.21,
      "trigger" : "both"
    }
  ],
  "sentences" : [
    { "id" : 0, "page" : 0, "text" : "Mais comment est-ce qu'ils arrivent à vendre leur pain aussi peu cher ?" },
    { "id" : 1, "page" : 0, "text" : "En réalité, c'est une vraie leçon d'organisation." }
  ],
  "started_at" : "2026-10-12T12:03:11Z",
  "takes" : [
    { "end" : 9.74, "sentence" : 0, "start" : 0.42, "status" : "completed" },
    { "end" : 12.76, "sentence" : 1, "start" : 9.74, "status" : "completed" },
    { "end" : 54.21, "sentence" : 5, "start" : 46.02, "status" : "abandoned" },
    { "end" : 61.88, "sentence" : 5, "start" : 56.9, "status" : "completed" }
  ],
  "title" : "Bakery",
  "version" : 1
}
```

## Fields

| Field | Meaning |
|---|---|
| `format`, `version` | Always `takeline.session` and `1` for this layout. A reader should refuse other values. |
| `app` | The app and version that wrote the file. |
| `title` | The script's file name, or its first words for an untitled script. |
| `languages` | Languages detected in the script (ISO 639 codes). |
| `started_at`, `ended_at` | ISO 8601 dates, from the Mac's clock. |
| `sentences` | Every sentence of the script, numbered across pages from 0. `page` is the page it belongs to; cues in [brackets] are left out of `text`. |
| `takes` | Each time the reader read a sentence, in order. `start` and `end` are seconds since `started_at`. |
| `takes[].status` | `completed`: read to the end. `abandoned`: stopped by a retake or a jump back, another take follows. `incomplete`: the session ended during it. |
| `retakes` | Each time the reader started a sentence over, with `time` in seconds since `started_at` and the `sentence` redone. |
| `retakes[].trigger` | `phrase`: a phrase such as "on la refait" or "take two" (the words heard are in `phrase`). `reread`: the reader went back and read the sentence again. `both`: the two, within 10 seconds. |

## Using it in an editor

1. Find the clips recorded during the session: a clip's creation date (camera clock) falls between `started_at` and `ended_at` (Mac clock). Allow for a few seconds of drift between the two clocks.
2. Line the clip's transcript up with `sentences[].text` to find where each sentence was said. The take times give the order and roughly where each attempt is; the transcript gives the exact cut points.
3. For each sentence, keep the last `completed` take and drop the `abandoned` ones before it, along with the retake phrases themselves.
