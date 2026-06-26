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
        Decide what the final viewer subtitle track should contain from both dialogue and on-screen text.
        Dialogue may be preserved, lightly rewritten, merged, or dropped when it is redundant, non-meaningful, or not useful as a final subtitle.
        Keep text short: one line preferred, two lines maximum.
        On-screen text is not dialogue; preserve, rewrite, or distill useful on-screen context only in parentheses, e.g. "(caption: ...)" or "(sign: ...)".
        Preserve or rewrite on-screen text when it contains unique information not spoken in dialogue.
        If there is too much on-screen text, distill the unique useful parts in one short parenthetical cue.
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
        The job is to discern what should become the final subtitles from both dialogue and on-screen text.
        This is editorial subtitle distillation, not scene summarization.
        Output should remain dense enough to follow the scene moment by moment, but it does not need to preserve every input cue.

        Dialogue:
        Dialogue is the main subtitle text and must not be wrapped in parentheses.
        For each input cue whose kind is "dialogue", decide whether it belongs in the final subtitle track.
        Preserve or lightly rewrite dialogue when it carries meaning, tone, turn-taking, plot, jokes, reactions, or information viewers need.
        You may drop dialogue when it is redundant with nearby dialogue or on-screen text, filler, false recognition, repeated, non-meaningful, or not useful as a viewer subtitle.
        Do not remove dialogue merely because the sentence is long; split or lightly polish instead.
        Do not collapse multiple meaningful dialogue turns into a scene summary.

        Readability:
        Keep each subtitle short enough to read at video speed.
        Prefer one line. Use two lines only when necessary.
        Avoid long comma-chained sentences. Split long speech into nearby shorter cues when timing allows.
        Aim for about 42 characters per line in English, and never more than two visual lines.
        Remove filler only when it does not change the speaker's meaning or tone.
        If shortening a cue would remove meaning, keep the longer wording.

        On-screen text:
        On-screen text is different from dialogue and must be wrapped in parentheses.
        Use concise labels for on-screen text when helpful: "(caption: ...)", "(sign: ...)", "(phone: ...)", "(name tag: ...)".
        For each input cue whose kind is "onScreen", decide whether it adds final-subtitle value.
        You may preserve the on-screen text, rewrite it for readability, or distill several on-screen cues into concise context.
        Useful on-screen text includes captions that explain jokes, reactions, speaker labels, rankings/scores, missions, signs, phone/chat text, or plot context.
        If an output cue combines dialogue and useful on-screen text, put dialogue first and on-screen text after it in parentheses only if it still fits within two lines.
        If dialogue and on-screen text communicate the same meaning, keep only the dialogue.
        Korean shows often display many simultaneous captions, labels, banners, score bugs, or decorative text.
        Do not include every on-screen text fragment.
        On-screen text is secondary to dialogue, but it is not disposable when it carries unique information.
        Preserve, rewrite, or distill on-screen text that is not present in dialogue and helps the viewer understand who/what/where/why.
        Keep on-screen text only when it adds meaning, emotion, speaker context, jokes, labels, signs, chats, or plot-relevant information.
        If there are too many useful on-screen text pieces at once, keep the most important unique item or summarize the unique useful parts in one short parenthetical cue.
        Drop on-screen text only when it is decorative, redundant with dialogue, repeated nearby, a logo/watermark, a production label, or recognition noise.
        Drop logos, watermarks, repeated decoration, production labels, recognition noise, and partial garbage text.

        Merging:
        Merge overlapping or adjacent duplicates into one cue.
        Use overlap context to decide when dialogue and on-screen text should become one bottom cue instead of simultaneous stacked subtitles.
        If merging adjacent dialogue cues, preserve the meaning of every merged dialogue cue.
        Do not stack dialogue and on-screen text as separate simultaneous subtitles.
        The output cue count can be lower than the input cue count when the final subtitles are clearer that way.
        Avoid overly sparse output that loses moment-by-moment meaning.
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
