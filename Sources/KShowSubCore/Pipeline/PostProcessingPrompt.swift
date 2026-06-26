import Foundation

enum PostProcessingPrompt {
    enum Profile {
        case appleIntelligence
        case openAI
    }

    static func systemPrompt(locale: Locale, profile: Profile) -> String {
        let language =
            locale.language.languageCode?.identifier
            ?? String(locale.identifier.prefix(2))
        switch profile {
        case .appleIntelligence:
            return appleIntelligenceSystemPrompt(language: language)
        case .openAI:
            return openAISystemPrompt(language: language)
        }
    }

    private static func appleIntelligenceSystemPrompt(language: String) -> String {
        """
        Edit Korean-show subtitles from a batch of timestamped cues in \(language).
        Return one unified bottom subtitle track. This is cleanup, not summarization.
        Inputs include context that identifies dialogue cues and on-screen text cues.
        Keep every meaningful dialogue cue unless duplicate or garbage.
        Never drop dialogue just to make output shorter.
        Keep text short: one line preferred, two lines maximum.
        On-screen text is not dialogue; include useful on-screen text only in parentheses, e.g. "(caption: ...)" or "(sign: ...)".
        Preserve on-screen text when it contains unique information not spoken in dialogue.
        If there is too much on-screen text, keep or summarize the unique useful parts in one short parenthetical cue.
        Drop logos, watermarks, decorative captions, repeated on-screen text, and noise.
        Preserve timestamps and chronology.
        Return only JSON: {"cues":[{"startTime":0,"endTime":1000,"text":"..."}]}.
        """
    }

    private static func openAISystemPrompt(language: String) -> String {
        """
        You are editing subtitles for Korean shows that will be watched with English subtitles.
        Inputs are batches of timestamped cues from the same video in \(language).
        Each batch contains explicit context: which cues are dialogue, which cues are on-screen text, and which cues overlap in time.
        Produce one readable, unified bottom subtitle track optimized for viewers.
        This is subtitle cleanup, not summarization.
        Output should remain dense enough to follow the scene moment by moment.
        Preserve every meaningful dialogue line unless it is a clear duplicate or recognition garbage.
        For each input cue whose kind is "dialogue", produce an output cue unless that dialogue is a duplicate of nearby dialogue or obvious recognition garbage.
        Prefer false positives over false negatives for dialogue: if unsure, keep it.
        Do not remove dialogue words merely because the sentence is long; split or lightly polish instead.
        Do not collapse multiple dialogue turns into a summary.
        When unsure whether dialogue is meaningful, keep it.

        Readability:
        Keep each subtitle short enough to read at video speed.
        Prefer one line. Use two lines only when necessary.
        Avoid long comma-chained sentences. Split long speech into nearby shorter cues when timing allows.
        Aim for about 42 characters per line in English, and never more than two visual lines.
        Remove filler only when it does not change the speaker's meaning or tone.
        If shortening a cue would remove meaning, keep the longer wording.

        Dialogue vs on-screen text:
        Dialogue is the main subtitle text and must not be wrapped in parentheses.
        On-screen text is different from dialogue and must be wrapped in parentheses.
        Use concise labels for on-screen text when helpful: "(caption: ...)", "(sign: ...)", "(phone: ...)", "(name tag: ...)".
        If an output cue combines dialogue and useful on-screen text, put dialogue first and on-screen text after it in parentheses only if it still fits within two lines.
        If dialogue and on-screen text say the same thing, keep only the dialogue.

        Handling excessive on-screen text:
        Korean shows often display many simultaneous captions, labels, banners, score bugs, or decorative text.
        Do not include every on-screen text fragment.
        On-screen text is secondary to dialogue, but it is not disposable when it carries unique information.
        Preserve on-screen text that is not present in dialogue and helps the viewer understand who/what/where/why.
        Keep on-screen text only when it adds meaning, emotion, speaker context, jokes, labels, signs, chats, or plot-relevant information.
        Preserve unique captions that explain jokes, reactions, speaker labels, rankings/scores, missions, signs, phone/chat text, or plot context.
        If there are too many useful on-screen text pieces at once, keep the most important unique item or summarize the unique useful parts in one short parenthetical cue.
        Drop on-screen text only when it is decorative, redundant with dialogue, repeated nearby, a logo/watermark, a production label, or recognition noise.
        Drop logos, watermarks, repeated decoration, production labels, recognition noise, and partial garbage text.

        Merging:
        Merge overlapping or adjacent duplicates into one cue.
        Use overlap context to decide when dialogue and on-screen text should become one bottom cue instead of simultaneous stacked subtitles.
        If merging adjacent dialogue cues, preserve the meaning of every merged dialogue cue.
        Do not stack dialogue and on-screen text as separate simultaneous subtitles.
        It is acceptable for the output cue count to be close to the input dialogue cue count; avoid overly sparse output.
        A good output usually has nearly as many dialogue cues as meaningful input dialogue cues.
        Preserve chronology and millisecond timestamps. You may extend a cue only enough to cover merged source cues.
        If the input is already English, output polished English. If the input is Korean or mixed Korean/English, preserve the source meaning cleanly so a later translation step can translate it naturally.
        Return only JSON: {"cues":[{"startTime":0,"endTime":1000,"text":"..."}]}.
        Do not use markdown, comments, explanations, or extra keys.
        """
    }

    static func systemPrompt(locale: Locale) -> String {
        systemPrompt(locale: locale, profile: .openAI)
    }

    static func userPrompt(batch: PostProcessingInputBatch) -> String {
        let cues = batch.cues.map { cue in
            [
                "index": cue.index,
                "source": cue.source,
                "kind": cue.kind.rawValue,
                "startTime": cue.startTime,
                "endTime": cue.endTime,
                "text": cue.text,
            ] as [String: Any]
        }
        let overlaps = batch.context.overlaps.map { overlap in
            [
                "index": overlap.index,
                "overlaps": overlap.overlaps,
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "cues": cues,
            "context": [
                "dialogueIndexes": batch.context.dialogueIndexes,
                "onScreenIndexes": batch.context.onScreenIndexes,
                "unknownIndexes": batch.context.unknownIndexes,
                "overlaps": overlaps,
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return "Input batch:\n\(json)"
    }
}
