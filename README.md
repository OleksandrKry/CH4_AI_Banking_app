# AI Banking Assistant

## Technical Exploration Report

---

# 1. Present Your Team

## Team Members

| Name | Role |
|------|------|
| Alex | Project Manager, Software Engineer |
| Artem |  UI/UX Designer |
| Bagus | Backend & AI Engineer |
| Raffi | Frontend Engineer |
| Gian | Fullstack Engineer |

## Project Overview

Our project is an on-device AI banking assistant built using Apple Intelligence technologies. Users can interact with the assistant through voice or text to ask banking-related questions. The application retrieves relevant banking products and documentation using semantic search and generates responses using Apple's Foundation Models. All data, including conversations, is stored locally to prioritize privacy.

---

# 2. Starting Assumption

> **Note:** This section reflects our initial assumptions before any experimentation and will not be modified later.

## We think we'll end up using

- SpeechAnalyzer for speech-to-text transcription
- Foundation Models for natural language understanding and response generation
- SwiftData for storing products, documentation, and conversation history
- NLContextualEmbeddings for semantic search and retrieval

## Because

These frameworks are part of Apple's AI ecosystem and appear to integrate well together for building an on-device AI assistant. We believe semantic retrieval combined with a Foundation Model will produce more relevant answers than simple keyword matching while keeping user data private.

---

# 3. The Exploration Log

> This section will be updated throughout the project.

## What we browsed, and what surprised us

### Documentation

- Apple SpeechAnalyzer
- Apple Foundation Models
- SwiftData
- NLContextualEmbeddings
- Retrieval-Augmented Generation (RAG) concepts

### Unexpected findings

- *(To be completed during development.)*

---

## What we actually built or tested

### Completed

- Created GitHub repository
- Configured Git with SSH authentication
- Created Jira project
- Created Kanban board
- Defined project architecture
- Assigned team responsibilities
- Created project documentation

### Planned experiments

- Prototype SpeechAnalyzer
- Create SwiftData models
- Generate contextual embeddings
- Build retrieval pipeline
- Integrate Foundation Models
- Test AI responses

---

## What we discovered that we didn't expect

*(To be completed during development.)*

---

# 4. What We Tried and Dropped

> This section will be completed after experimentation.


---

# 5. Real Limitations Hit

> This section will be updated as development progresses.

Potential topics include:

- Foundation Model limitations
- Embedding quality
- Speech recognition accuracy
- Simulator vs physical device limitations
- Apple Intelligence availability
- Performance issues

---

# 6. The Revised Decision

> This section will be completed near the end of the project.

## Final decision

*(To be completed.)*

## What changed since Section 1, and why

*(To be completed.)*

---

# App Track Addendum

## About the Frameworks

Our current architecture combines several Apple frameworks to provide an on-device AI experience.

- **SpeechAnalyzer** converts spoken questions into text.
- **Foundation Models** interpret user requests and generate responses.
- **SwiftData** stores banking products, documentation, and conversation history.
- **NLContextualEmbeddings** retrieves relevant information using semantic similarity.

During development, we will evaluate whether using semantic retrieval provides a measurable improvement over traditional keyword search.

---

## About Accessibility and Localization

*(To be completed during development.)*


---

## About Privacy

Our application is designed with privacy as a priority.

### Data stored locally

- Banking products
- Banking documentation
- Conversation history

### Permissions

**Microphone**

Used only for voice input. If microphone permission is denied, users can continue using the application by typing their questions.

No personal banking credentials, financial account information, or sensitive user data will be collected or transmitted.

---

## Project Status

### Current Progress

- ✅ Repository created
- ✅ GitHub configured
- ✅ Jira Kanban board created
- ✅ Initial project planning completed
- ⏳ AI prototype in progress
- ⏳ SwiftData implementation pending
- ⏳ Retrieval pipeline pending
- ⏳ Foundation Models integration pending
