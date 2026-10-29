import Foundation

public enum BuiltInTemplates {
    public static let general = MeetingTemplate(
        id: "general",
        title: "General Meeting",
        description: "A balanced summary for any conversation, with a diagram of how it fits together.",
        icon: "📝",
        sections: [
            .init(title: "Overview", description: "Two or three sentences: who met, why, and the main outcome."),
            .init(title: "Visual Summary", description: "One Mermaid diagram (two at most) that makes the meeting easy to grasp at a glance. Pick the type that fits what was said: a flowchart from topics to decisions to owners and actions, a mindmap of themes, a timeline of dates and milestones, a sequenceDiagram of hand-offs between people, or a gantt chart when tasks have dates. Add one short sentence under it saying what it shows."),
            .init(title: "Key Points", description: "The most important topics discussed, as bullets, attributed to speakers where it matters."),
            .init(title: "Decisions", description: "Decisions that were made. Omit nothing that was agreed."),
            .init(title: "Action Items", description: "A Markdown table with the columns Owner | Task | Due (write '—' when no date was given), one row per follow-up. Write 'None discussed.' instead of a table if there are none."),
        ],
        builtIn: true
    )

    public static let oneOnOne = MeetingTemplate(
        id: "one-on-one",
        title: "1-1 Meeting",
        description: "Check-in between two people: updates, feedback, and follow-ups.",
        icon: "🤝",
        sections: [
            .init(title: "Overview", description: "Two or three sentences on who met and the main themes."),
            .init(title: "Updates", description: "Progress, wins, and blockers each person shared, grouped by speaker."),
            .init(title: "Feedback & Discussion", description: "Feedback in either direction, concerns raised, and decisions reached."),
            .init(title: "Career & Wellbeing", description: "Growth, goals, workload, or morale. Write 'None discussed.' if absent."),
            .init(title: "Action Items", description: "'Owner: task (due date if mentioned)' for every follow-up."),
        ],
        builtIn: true
    )

    public static let brainstorming = MeetingTemplate(
        id: "brainstorming",
        title: "Brainstorming",
        description: "Capture ideas, themes, trade-offs, and the chosen direction.",
        icon: "💡",
        sections: [
            .init(title: "Goal", description: "The problem or question the group set out to explore."),
            .init(title: "Ideas", description: "Every distinct idea raised, one bullet each, credited to who proposed it."),
            .init(title: "Themes & Trade-offs", description: "Group related ideas into themes and note pros, cons, and risks discussed."),
            .init(title: "Leading Options", description: "Which ideas the group favoured or decided to pursue, and why."),
            .init(title: "Open Questions", description: "Unresolved questions or assumptions that need validation."),
            .init(title: "Next Steps", description: "'Owner: task' for each agreed follow-up."),
        ],
        builtIn: true
    )

    public static let dailyStandup = MeetingTemplate(
        id: "daily-standup",
        title: "Daily Standup",
        description: "Per-person yesterday / today / blockers, kept short.",
        icon: "☀️",
        sections: [
            .init(title: "Updates by Person", description: "One sub-heading (###) per speaker. Under each: Yesterday, Today, Blockers. One line each where possible."),
            .init(title: "Blockers & Risks", description: "All blockers consolidated across speakers: who is affected and who can help."),
            .init(title: "Announcements", description: "Reminders, schedule changes or FYIs. Write 'None.' if absent."),
            .init(title: "Action Items", description: "'Owner: task' for anything agreed during the standup."),
        ],
        builtIn: true
    )

    public static let customerDemo = MeetingTemplate(
        id: "customer-demo",
        title: "Customer Demo",
        description: "What was shown, customer reactions, objections, and next steps.",
        icon: "🎯",
        sections: [
            .init(title: "Attendees & Context", description: "Who attended from the customer side and ours, and the customer's stated goals."),
            .init(title: "What Was Demoed", description: "Features and workflows shown, in the order presented."),
            .init(title: "Customer Reactions & Feedback", description: "Positive reactions, confusion and feature requests. Quote notable remarks with the speaker."),
            .init(title: "Questions & Objections", description: "Each question or concern and how it was answered. Flag anything left unanswered."),
            .init(title: "Buying Signals & Risks", description: "Interest level, budget/timeline/decision-maker mentions, competitor references."),
            .init(title: "Next Steps", description: "'Owner: task (due date)' covering follow-up material, trials and meetings."),
        ],
        builtIn: true
    )

    public static let all: [MeetingTemplate] = [general, oneOnOne, brainstorming, dailyStandup, customerDemo]
}
