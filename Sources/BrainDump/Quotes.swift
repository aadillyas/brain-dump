import Foundation

struct Quote {
    let text: String
    let author: String?
}

enum Quotes {
    static let all: [Quote] = [
        // Attributed quotes (well-documented sources only)
        Quote(text: "I write entirely to find out what I’m thinking, what I’m looking at, what I see and what it means.", author: "Joan Didion"),
        Quote(text: "The unexamined life is not worth living.", author: "Socrates"),
        Quote(text: "Your mind is for having ideas, not holding them.", author: "David Allen"),
        Quote(text: "We suffer more often in imagination than in reality.", author: "Seneca"),
        Quote(text: "Life can only be understood backwards; but it must be lived forwards.", author: "Søren Kierkegaard"),
        Quote(text: "The question is not what you look at, but what you see.", author: "Henry David Thoreau"),
        Quote(text: "How vain it is to sit down to write when you have not stood up to live.", author: "Henry David Thoreau"),
        Quote(text: "A journey of a thousand miles begins with a single step.", author: "Lao Tzu"),
        Quote(text: "We write to taste life twice, in the moment and in retrospection.", author: "Anaïs Nin"),
        Quote(text: "How we spend our days is, of course, how we spend our lives.", author: "Annie Dillard"),
        Quote(text: "Almost all good writing begins with terrible first efforts.", author: "Anne Lamott"),

        // Original tips
        Quote(text: "Writing a worry down makes it smaller.", author: nil),
        Quote(text: "Your head is a poor filing cabinet. Paper and screens are much better at it.", author: nil),
        Quote(text: "You don’t have to make sense yet. Just get it out.", author: nil),
        Quote(text: "A messy page is better than a tidy thought you never wrote down.", author: nil),
        Quote(text: "Thoughts that loop in your head often settle once they’re on the page.", author: nil),
        Quote(text: "Five minutes of writing a day adds up to a record of your whole year.", author: nil),
        Quote(text: "Name the thing that’s bothering you. Naming it is half of dealing with it.", author: nil),
        Quote(text: "Ideas are slippery. Capture them before they wander off.", author: nil),
        Quote(text: "Clearing your mind isn’t about emptiness. It’s about knowing where everything is.", author: nil),
        Quote(text: "Not every thought needs action. Some just need to be heard.", author: nil),
        Quote(text: "Look back at old entries now and then. You’ve handled more than you remember.", author: nil),
        Quote(text: "Small habits beat big intentions. Show up, say a little, repeat tomorrow.", author: nil),
        Quote(text: "Honest and rough is more useful than polished and guarded.", author: nil),
        Quote(text: "Separate the urgent from the loud. Writing everything down makes the difference visible.", author: nil),
        Quote(text: "A clear morning often starts with an honest few minutes of talking it through.", author: nil),
        Quote(text: "Reflection turns a busy day into something you can learn from.", author: nil),
        Quote(text: "If a task keeps nagging you, it probably needs to be written down somewhere trusted.", author: nil),
        Quote(text: "Good ideas often hide in the middle of a ramble. Keep going.", author: nil),
        Quote(text: "Notice what you keep coming back to. That’s usually what matters.", author: nil),
        Quote(text: "Taking a slow breath before you start makes the next few minutes clearer.", author: nil),
    ]
}
