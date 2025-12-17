# Unified API

<cite>
**Referenced Files in This Document**   
- [main.py](file://litellm/main.py)
- [get_llm_provider_logic.py](file://litellm/litellm_core_utils/get_llm_provider_logic.py)
- [images/main.py](file://litellm/images/main.py)
- [__init__.py](file://litellm/__init__.py)
</cite>

## Table of Contents
1. [Introduction](#introduction)
2. [Core Functions Implementation](#core-functions-implementation)
3. [Request/Response Transformation and Error Handling](#requestresponse-transformation-and-error-handling)
4. [Practical Usage Examples](#practical-usage-examples)
5. [Adapter Pattern Architecture](#adapter-pattern-architecture)
6. [Provider Detection and Fallback Mechanism](#provider-detection-and-fallback-mechanism)
7. [Performance Considerations](#performance-considerations)
8. [Conclusion](#conclusion)

## Introduction
The Unified API concept in LiteLLM provides a standardized interface for interacting with over 100 different LLM providers. This abstraction layer allows developers to use a consistent API signature regardless of the underlying provider, simplifying integration and enabling seamless switching between different LLM services. The core of this functionality is implemented in the `main.py` file, which exposes standardized functions for completion, embedding, and image generation operations.

## Core Functions Implementation

The main.py file implements the core functions that form the Unified API abstraction layer. These functions standardize interactions across all supported LLM providers through a consistent interface.

### Completion Function
The `completion()` function serves as the primary interface for text generation across all providers. It accepts a standardized set of parameters that map to provider-specific APIs:

- **model**: Specifies the LLM to use (e.g., "gpt-3.5-turbo", "claude-2")
- **messages**: Array of message objects with role and content
- **temperature**, **top_p**, **n**: Standard sampling parameters
- **stream**: Boolean for streaming responses
- **max_tokens**: Maximum tokens in the response
- **tools**: Function calling/tool use configuration

The function handles parameter mapping to provider-specific APIs through the `get_optional_params()` function, which transforms the standardized parameters into the format required by each provider.

### Embedding Function
The embedding functionality provides a unified interface for generating vector embeddings across different providers. The implementation follows the same pattern as the completion function, accepting standardized parameters and mapping them to provider-specific requirements.

### Image Generation Function
The `image_generation()` function standardizes image creation across providers with parameters like:
- **prompt**: Text description of the desired image
- **size**: Dimensions of the generated image
- **n**: Number of images to generate
- **quality**: Image quality setting
- **style**: Artistic style preference

**Section sources**
- [main.py](file://litellm/main.py#L987-L1039)
- [images/main.py](file://litellm/images/main.py#L73-L284)

## Request/Response Transformation and Error Handling

### Request Transformation Process
The request transformation process follows a systematic approach to convert standardized API calls into provider-specific formats:

1. **Provider Detection**: The `get_llm_provider()` function analyzes the model name and other parameters to determine the appropriate provider.
2. **Parameter Mapping**: Standardized parameters are transformed into provider-specific formats using configuration classes in the `llms/` directory.
3. **API Call Construction**: The transformed parameters are used to construct the appropriate HTTP request for the target provider.

The transformation process handles differences in parameter names, value formats, and required fields across providers, ensuring that the same standardized API call works consistently regardless of the backend service.

### Response Normalization
Response normalization ensures that outputs from different providers follow a consistent structure:

- **Standardized Response Format**: All providers return responses in the same format, with consistent field names and data types.
- **Error Code Mapping**: Provider-specific error codes are translated into standardized LiteLLM error types.
- **Metadata Enrichment**: Responses include additional metadata like token counts and latency information.

### Error Handling Normalization
LiteLLM implements comprehensive error handling normalization:

- **Standardized Exception Types**: Provider-specific errors are wrapped in standardized LiteLLM exception classes.
- **Retry Logic**: Automatic retry mechanisms handle transient failures.
- **Fallback Support**: When configured, the system can automatically retry failed requests with alternative providers.
- **Detailed Error Information**: Errors include provider-specific details while maintaining a consistent interface.

The error handling system ensures that applications can handle errors consistently regardless of which provider generated the error.

**Section sources**
- [main.py](file://litellm/main.py#L1084-L1088)
- [main.py](file://litellm/main.py#L1474-L1490)

## Practical Usage Examples

### OpenAI Integration
```python
import litellm

# Standard API call to OpenAI
response = litellm.completion(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "Hello, how are you?"}]
)
```

### Anthropic Integration
```python
import litellm

# Same API signature for Anthropic
response = litellm.completion(
    model="claude-2",
    messages=[{"role": "user", "content": "Hello, how are you?"}]
)
```

### Google Gemini Integration
```python
import litellm

# Identical API call for Google Gemini
response = litellm.completion(
    model="gemini-pro",
    messages=[{"role": "user", "content": "Hello, how are you?"}]
)
```

### Provider-Specific Parameters
```python
import litellm

# Using provider-specific parameters while maintaining the standard interface
response = litellm.completion(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "Hello, how are you?"}],
    # OpenAI-specific parameter
    presence_penalty=0.5,
    # Standard parameter that works across providers
    temperature=0.7
)
```

These examples demonstrate how the Unified API allows developers to switch between providers with minimal code changes, promoting flexibility and reducing vendor lock-in.

**Section sources**
- [main.py](file://litellm/main.py#L987-L1039)

## Adapter Pattern Architecture

The adapter pattern in the `litellm/llms/` directory encapsulates provider-specific logic, enabling the unified interface. Each provider has its own subdirectory containing the adapter implementation.

### Adapter Structure
Each provider adapter follows a consistent structure:
- **Configuration Classes**: Define provider-specific parameters and their mapping to the standard API.
- **Transformation Logic**: Convert standardized requests to provider-specific formats.
- **Response Handlers**: Normalize provider responses to the standard format.
- **Error Mappers**: Translate provider-specific errors to standardized exceptions.

### Provider-Specific Implementation
The architecture separates concerns by isolating provider-specific code:
- **OpenAI**: Adapters handle OpenAI's specific authentication, parameter names, and response formats.
- **Anthropic**: Specialized handlers manage Anthropic's unique message format and streaming behavior.
- **Bedrock**: Adapters translate between the standard API and AWS Bedrock's request structure.
- **Vertex AI**: Implementation handles Google Cloud authentication and API conventions.

### Base Classes and Inheritance
The system uses base classes to define common behavior:
- **BaseLLM**: Provides shared functionality for all LLM providers.
- **BaseConfig**: Defines the interface for provider configuration and parameter mapping.
- **Provider-Specific Base Classes**: Extend the base classes with provider-specific behavior.

This architecture enables new providers to be added by implementing the appropriate adapter classes while maintaining compatibility with the unified API.

**Section sources**
- [main.py](file://litellm/main.py#L1240-L1246)
- [__init__.py](file://litellm/__init__.py#L464-L560)

## Provider Detection and Fallback Mechanism

### Provider Detection Logic
The `get_llm_provider_logic.py` file implements sophisticated provider detection that determines the appropriate provider based on multiple factors:

- **Model Name Analysis**: The system parses the model name to identify the provider (e.g., "gpt-3.5-turbo" → OpenAI).
- **Custom Provider Specification**: Developers can explicitly specify the provider using the `custom_llm_provider` parameter.
- **API Base Detection**: When an API base URL is provided, the system can infer the provider from known endpoints.
- **Heuristic Rules**: Special rules handle edge cases and ambiguous model names.

The detection process is implemented in the `get_llm_provider()` function, which returns the detected provider along with any necessary configuration adjustments.

### Fallback Mechanism
When multiple providers support the same model, LiteLLM implements a fallback mechanism:

1. **Primary Provider Selection**: The system selects a primary provider based on configuration and availability.
2. **Health Checking**: Providers are monitored for availability and performance.
3. **Automatic Fallback**: When the primary provider fails, requests are automatically routed to backup providers.
4. **Context Preservation**: The fallback process maintains the original request context and parameters.

The fallback mechanism is configurable through parameters like `fallbacks` and `context_window_fallbacks`, allowing developers to customize the behavior based on their requirements.

### Priority Resolution
When conflicts arise in provider detection:
- **Explicit Configuration Takes Precedence**: Manually specified providers override automatic detection.
- **Known Provider List**: The system maintains a comprehensive list of known providers and their models.
- **Ambiguity Resolution**: Clear rules handle cases where multiple providers could potentially handle a request.

This sophisticated detection and fallback system ensures reliable operation even when individual providers experience issues.

**Section sources**
- [get_llm_provider_logic.py](file://litellm/litellm_core_utils/get_llm_provider_logic.py#L100-L441)

## Performance Considerations

### Translation Overhead
The Unified API introduces some overhead due to request/response transformation:

- **Parameter Mapping**: Converting standardized parameters to provider-specific formats adds minimal processing time.
- **Response Normalization**: Transforming provider responses to the standard format has negligible impact.
- **Provider Detection**: The initial provider detection is optimized for performance.

The overhead is typically measured in milliseconds and is generally insignificant compared to the actual LLM processing time.

### Latency Optimization Best Practices
To minimize latency when using the Unified API:

#### Use Connection Pooling
```python
# Reuse HTTP connections to reduce connection overhead
client = httpx.AsyncClient()
response = await litellm.acompletion(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "Hello"}],
    client=client  # Reuse the same client
)
```

#### Enable Streaming for Large Responses
```python
# Stream responses to start processing before completion
response = litellm.completion(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "Generate a long response"}],
    stream=True
)
```

#### Implement Caching
```python
# Cache repeated requests to avoid unnecessary API calls
litellm.enable_cache()
response = litellm.completion(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "Same question as before"}]
)
```

#### Use Asynchronous Calls
```python
# Use async/await for non-blocking operations
responses = await asyncio.gather(
    litellm.acompletion(model="gpt-3.5-turbo", messages=[{"role": "user", "content": "Question 1"}]),
    litellm.acompletion(model="gpt-3.5-turbo", messages=[{"role": "user", "content": "Question 2"}])
)
```

#### Optimize Provider Selection
- **Choose Low-Latency Providers**: Select providers with data centers geographically close to your users.
- **Monitor Performance**: Track response times and adjust provider selection accordingly.
- **Use Local Models**: When possible, use locally hosted models to eliminate network latency.

These best practices help ensure that the Unified API delivers optimal performance while maintaining its flexibility and ease of use.

**Section sources**
- [main.py](file://litellm/main.py#L364-L366)
- [main.py](file://litellm/main.py#L634-L649)

## Conclusion
The Unified API in LiteLLM provides a powerful abstraction layer that standardizes interactions with over 100 LLM providers through a consistent interface. By implementing the adapter pattern in the `litellm/llms/` directory, the system encapsulates provider-specific logic while exposing a unified API for completion, embedding, and image generation operations. The sophisticated provider detection in `get_llm_provider_logic.py` ensures accurate routing of requests, while the fallback mechanism provides reliability. With proper implementation of performance best practices, the minimal translation overhead is outweighed by the benefits of provider flexibility and simplified integration. This architecture enables developers to build applications that can seamlessly leverage multiple LLM providers while maintaining a clean, consistent codebase.