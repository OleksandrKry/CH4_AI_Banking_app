# Banking Assistant — Behavioral Requirements

Requirements the assistant must satisfy, each mapped to the test(s) that verify
it. Model-gated tests need Apple Intelligence (they skip on hosts without it);
retrieval tests run everywhere the NL embedding assets exist; the headless
harness `scripts/retrieval-eval.sh` runs on macOS with no simulator.

| ID | Requirement | Verified by |
|----|-------------|-------------|
| R1 | Every product is exactly one retrieval chunk; no duplicate products. | `RetrievalAccuracyTests.everyProductIsExactlyOneChunk` |
| R2 | Core retrieval accuracy (contextual model, production config): Hit@1 ≥ 0.70, Hit@3 ≥ 0.85, MRR ≥ 0.75 over the 22-query golden set. | `RetrievalAccuracyTests.goldenSetAccuracyMeetsFloors` |
| R3 | Edge inputs (typos, one-word "dummy" queries, Indonesian/English code-switching) still steer to the right product branch: Hit@3 ≥ 0.6. | `goldenSetAccuracyMeetsFloors` (edge block), CLI edge section |
| R4 | Retrieval confidence separates in-scope from out-of-scope queries (max negative < 25th-percentile positive); hits under the 0.25 floor are dropped. | `goldenSetAccuracyMeetsFloors` (separation assertion) |
| R5 | A broad first query starts qualification: the app's sequential intake flow (3–6 questions, generated once) fronts every new conversation; at the raw RAG level the model prefers asking over dumping products (best-effort, recorded as intermittent known-issue). | Intake flow in `ChatViewModel` + `RAGSystemTests.broadFirstQueryQualifiesBeforeRecommending` |
| R6 | Qualifying questions are AI-generated, asked ONE per turn, and rendered with tappable options + "your own answer" + Skip. | `QuestionCardView` (+ structuring step in `generateResponse`); manual UI check |
| R7 | Follow-ups about already-shown products never swap in different products (answering from the transcript preferred; re-fetching the same products tolerated). | `RAGSystemTests.followUpAboutShownProductAnswersFromContext` |
| R8 | Asking for new/different products triggers the catalog tool again. | `RAGSystemTests.askingForDifferentProductsRetrievesAgain` |
| R9 | Off-topic requests get a polite decline/steer with NO product cards (tool confidence floor guarantees empty cards). | `RAGSystemTests.offTopicQueryDeclinesWithoutProducts` |
| R10 | Gibberish and out-of-domain shopping wishes ("I want a new iPhone") never crash the flow. | `RAGSystemTests.roughInputNeverLeaksRawErrors` |
| R11 | Raw framework errors never reach the chat; failures map to friendly, actionable text, and model unavailability is explained (enable/downloading/ineligible). | `roughInputNeverLeaksRawErrors`; `RAGSystem.friendlyFailureMessage` / `modelUnavailableMessage` + availability gate |
| R12 | Product cards, citations, and confidence reflect ONLY what the model actually consulted via the tool this turn. | `RAGSystemTests.generateResponsePersistsUserThenAssistantMessage` + `ProductCatalogTool` design |
| R13 | Conversation intent is AI-classified into a decision-tree category (constrained decoding — always a valid category). | `RAGSystemTests.intentClassificationPicksATreeCategory` |
| R14 | Answers: 3–4 sentences, no raw delimiters, user's language. | `RAGSystemTests.generatedAnswerObeysNoPipeDelimiterConstraint`; language rule checked manually |
| R15 | Context window (4,096 tokens) is managed: instructions once per session, compact tool output, condensed-transcript recovery; per-turn stage timings + context estimate are recorded. | `RAGSystemTests.turnMetricsCaptureStageTimings`; `TurnMetrics` debug logs |
| R16 | Routing is the session model's TOOL CHOICE (no app-side pre-routing): greetings/identity/general questions answer directly; unqualified product needs call `askQualifyingQuestions` (the app then runs the 3–6-question flow); qualified needs call `searchProductCatalog`. "Hi" / "how are you?" never trigger a workflow. | `RAGSystemTests.greetingsAnswerDirectlyWithoutWorkflows`, `productQueryTriggersQuestionnaireOrRecommendation` |
| R17 | Stopping voice dictation never shows an error banner — recognition cancellation is an expected outcome. | Cancellation filter in `SpeechRecognizer` (manual check) |

Manual checks (not automatable cheaply): answer language mirroring, qualifying
question UX feel, and the visual design of cards/sheets. Recalibrate confidence
and floors with `scripts/retrieval-eval.sh` whenever `bca-products.json`, the
embedding scheme, fusion weights, or the confidence formula change.
