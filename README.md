# AI Buddy using Gemini LLM and Flutter


<!-- PROJECT LOGO -->


<br />
<div align="center">
  <a href="https://github.com/yatendra2001/ai_buddy">
    <img src="https://github.com/yatendra2001/gemini_chat/assets/62821607/1e31abfa-7fe7-4775-a6c7-185ba03b48ef"  alt="Logo" width="200" height="200" >
  </a>
  <h1 align="center" >AI Buddy</h1>
  <h4 align="center">
    Your personal completely open-sourced and free-to-use AI assistant, built with gemini & flutter.
  </h4>
</div> 



<!-- Project Features -->
## Features

AI Buddy is a cross-platform mobile application that leverages the power of AI to provide users with a personal assistant capable of understanding and responding to various queries.

| Chat with PDF | Ask Image | Text Chatbot | 
| --- | ----------- | ------ | 
| <img height="500" alt="Chat with PDF" src="https://github.com/yatendra2001/gemini_chat/assets/62821607/66c9a316-0e34-42e4-a791-912e78a582da"> | <img height="500" alt="Ask Image" src="https://github.com/yatendra2001/gemini_chat/assets/62821607/983911b5-22a9-40bf-8a16-7b1294f3e44e"> | <img height="500" alt="Text Chatbot" src="https://github.com/yatendra2001/gemini_chat/assets/62821607/f26221c7-666b-49b3-91ee-47ec17dba728"> |

<!-- ARCHITECTURE -->
## Architecture

The architecture of the AI Buddy app is designed to efficiently process and interact with PDF documents. Here's a breakdown of the workflow:

### Overview

The "Chat with PDF" feature of the AI Buddy app allows users to interact with the content of a PDF document in a conversational manner. The app extracts information from the PDF, processes it, and provides relevant responses to user queries.

### Workflow Diagram

![Chat with PDF Flutter App Architecture](https://github.com/yatendra2001/ai_buddy/assets/62821607/71492eb4-0521-43e7-a3ca-f0bdc05c679e)

### Workflow Steps

1. **PDF Extraction**: The PDF document is processed to extract its pages.

2. **Chunking**: The extracted pages are then split into manageable chunks for processing.

3. **Batching**: Chunks are grouped into batches (e.g., 1 batch = 100 chunks) for parallel processing.

4. **Embedding Generation**: Each batch is sent to an Embeddings API with the task type set to 'Document'. The API generates a list of vector embeddings for each chunk.

5. **Local Storage**: The generated embeddings for each batch are split into individual chunk embeddings. These embeddings are stored locally using Hive (a key-value database).

6. **User Interaction**: When a user inputs an instruction (e.g., "Give me an intro to the book"), the app sends the query to the Embeddings API with the task type set to 'Query' to generate an embedding for the query.

7. **Semantic Search**: The app performs a semantic search by taking the embedding of the user's query and comparing it across the document embeddings stored in Hive.

8. **Ranking Results**: The chunks are ranked based on the Euclidean distance between the query embedding and document embeddings. The top-ranked chunks are used as the context for the language model (LLM).

9. **Response Generation**: The language model generates an answer based on the context provided by the top-ranked chunks.

### Technologies Used

- **Flutter**: For cross-platform mobile application development.
- **Hive**: For local storage of chunk embeddings.
- **Gemini Embeddings API**: For generating vector embeddings of text.
- **Gemini (LLM)**: For generating responses based on context.
- **Riverpod**: For managing states across the app.

<!-- GETTING STARTED -->
## Getting Started


### Prerequisites

Need the latest flutter version & a gemini api key from [here](https://makersuite.google.com/app/apikey)

```bash
  flutter upgrade
```

### Installation

1. Clone the repository from GitHub:

```bash
git clone https://github.com/CodeAlchemist09/AI-Chat-Buddy-using-Gemini-Flutter.git
```

2. Get all dependencies:
```bash
flutter pub get
```

3. Run the app:

```bash
flutter run
```



### Make sure to leave us a ⭐️
