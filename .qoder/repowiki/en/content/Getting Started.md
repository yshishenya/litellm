# Getting Started

<cite>
**Referenced Files in This Document**   
- [pyproject.toml](file://pyproject.toml)
- [README.md](file://README.md)
- [litellm/__init__.py](file://litellm/__init__.py)
- [litellm/main.py](file://litellm/main.py)
- [litellm/proxy/proxy_server.py](file://litellm/proxy/proxy_server.py)
- [litellm/proxy/proxy_cli.py](file://litellm/proxy/proxy_cli.py)
- [litellm/types/completion.py](file://litellm/types/completion.py)
- [cookbook/litellm_proxy_server/readme.md](file://cookbook/litellm_proxy_server/readme.md)
</cite>

## Table of Contents
1. [Introduction](#introduction)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Configuration](#configuration)
5. [Basic Usage Patterns](#basic-usage-patterns)
6. [Making API Calls](#making-api-calls)
7. [Synchronous vs Asynchronous Calls](#synchronous-vs-asynchronous-calls)
8. [Proxy Server Deployment](#proxy-server-deployment)
9. [Troubleshooting Common Issues](#troubleshooting-common-issues)
10. [Performance Considerations](#performance-considerations)
11. [Best Practices](#best-practices)

## Introduction
LiteLLM is a comprehensive library designed to simplify interactions with various Large Language Model (LLM) providers through a unified interface. It enables developers to call multiple LLM APIs using the OpenAI format, providing consistent input/output handling, retry/fallback logic, and support for advanced features like streaming and async operations. This guide provides a comprehensive overview of setting up LiteLLM, configuring environment variables, and utilizing its primary usage patterns for both direct library calls and proxy server deployment.

**Section sources**
- [README.md](file://README.md#L1-L503)

## Prerequisites
Before installing and using LiteLLM, ensure your environment meets the following requirements:

- **Python Version**: Python 3.9 or higher is required. LiteLLM supports Python versions from 3.9 up to 4.0.
- **Network Connectivity**: Ensure your system has internet access to connect to LLM providers such as OpenAI, Anthropic, and others.
- **API Keys**: Obtain API keys from the LLM providers you intend to use. These keys are essential for authentication when making API calls.
- **Environment Management**: It's recommended to use virtual environments (e.g., venv or conda) to manage dependencies and avoid conflicts with other projects.

LiteLLM's architecture is designed to work seamlessly across different operating systems and environments, making it suitable for both development and production deployments.

**Section sources**
- [pyproject.toml](file://pyproject.toml#L22-L23)
- [README.md](file://README.md#L49-L75)

## Installation
Installing LiteLLM is straightforward using pip, the Python package manager. The library can be installed in different configurations depending on your use case.

To install the core LiteLLM library:
```bash
pip install litellm
```

For proxy server functionality, install the proxy extras:
```bash
pip install 'litellm[proxy]'
```

The installation includes all necessary dependencies such as httpx for HTTP requests, tiktoken for token counting, and pydantic for data validation. Additional optional dependencies can be installed based on specific requirements, such as fastapi and uvicorn for running the proxy server, or various secret managers for secure credential handling.

**Section sources**
- [pyproject.toml](file://pyproject.toml#L21-L115)
- [README.md](file://README.md#L55-L57)
- [cookbook/litellm_proxy_server/readme.md](file://cookbook/litellm_proxy_server/readme.md#L133-L152)

## Configuration
Proper configuration is essential for LiteLLM to function correctly. The primary configuration involves setting environment variables for API keys and other provider-specific credentials.

Set your API keys as environment variables:
```bash
export OPENAI_API_KEY="your-openai-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
export VERTEX_PROJECT="your-project-id"
export VERTEX_LOCATION="your-region"
```

Alternatively, you can use a .env file to manage your environment variables:
```bash
echo 'OPENAI_API_KEY="your-openai-key"' > .env
echo 'ANTHROPIC_API_KEY="your-anthropic-key"' >> .env
```

LiteLLM automatically loads environment variables from .env files when running in development mode. For production deployments, ensure these variables are securely stored and accessed through your deployment platform's secret management system.

**Section sources**
- [README.md](file://README.md#L63-L66)
- [litellm/__init__.py](file://litellm/__init__.py#L93-L95)
- [litellm/main.py](file://litellm/main.py#L47)

## Basic Usage Patterns
LiteLLM supports two primary usage patterns: direct library calls and proxy server deployment. Each pattern serves different use cases and deployment scenarios.

### Direct Library Calls
Direct calls allow you to integrate LiteLLM directly into your Python applications. This approach is ideal for applications that need fine-grained control over LLM interactions.

```python
from litellm import completion
import os

# Set environment variables
os.environ["OPENAI_API_KEY"] = "your-openai-key"

# Create messages
messages = [{"content": "Hello, how are you?", "role": "user"}]

# Make completion call
response = completion(model="openai/gpt-4o", messages=messages)
print(response)
```

### Proxy Server Deployment
The proxy server acts as an intermediary between your application and LLM providers, offering additional features like rate limiting, cost tracking, and load balancing.

```bash
# Start the proxy server
litellm --model huggingface/bigcode/starcoder

# Make requests to the proxy
import openai
client = openai.OpenAI(api_key="anything", base_url="http://0.0.0.0:4000")
response = client.chat.completions.create(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "write a short poem"}]
)
```

**Section sources**
- [README.md](file://README.md#L59-L75)
- [cookbook/litellm_proxy_server/readme.md](file://cookbook/litellm_proxy_server/readme.md#L76-L100)
- [litellm/proxy/proxy_cli.py](file://litellm/proxy/proxy_cli.py#L132-L135)

## Making API Calls
LiteLLM provides a consistent interface for making API calls to various LLM providers. The library supports completion, embedding, and image generation requests across multiple platforms.

### Completion Requests
To make a completion request, use the `completion` function with the appropriate model identifier:

```python
from litellm import completion

messages = [{"content": "Hello, how are you?", "role": "user"}]

# OpenAI model
response = completion(model="openai/gpt-4o", messages=messages)

# Anthropic model
response = completion(model="anthropic/claude-sonnet-4-20250514", messages=messages)
```

### Embedding Requests
For embedding requests, use the `embedding` function:

```python
from litellm import embedding

response = embedding(
    model="openai/text-embedding-ada-002",
    input=["Hello world", "How are you?"]
)
```

Model identifiers follow the format `provider/model_name`, allowing you to easily switch between different providers and models.

**Section sources**
- [README.md](file://README.md#L69-L74)
- [litellm/types/completion.py](file://litellm/types/completion.py#L165-L193)
- [litellm/main.py](file://litellm/main.py#L366-L632)

## Synchronous vs Asynchronous Calls
LiteLLM supports both synchronous and asynchronous operations, allowing you to choose the appropriate pattern based on your application's requirements.

### Synchronous Calls
Synchronous calls block execution until the response is received:

```python
from litellm import completion

messages = [{"content": "Hello, how are you?", "role": "user"}]
response = completion(model="openai/gpt-4o", messages=messages)
print(response)
```

### Asynchronous Calls
Asynchronous calls allow non-blocking operations, improving performance in I/O-bound applications:

```python
from litellm import acompletion
import asyncio

async def get_response():
    messages = [{"content": "Hello, how are you?", "role": "user"}]
    response = await acompletion(model="openai/gpt-4o", messages=messages)
    return response

# Run the async function
response = asyncio.run(get_response())
print(response)
```

Asynchronous operations are particularly beneficial when making multiple requests concurrently or when integrating with async web frameworks.

**Section sources**
- [README.md](file://README.md#L117-L131)
- [litellm/main.py](file://litellm/main.py#L366-L632)

## Proxy Server Deployment
The LiteLLM proxy server provides a robust gateway for managing LLM requests with additional features like authentication, rate limiting, and cost tracking.

### Starting the Proxy Server
Start the proxy server using the command-line interface:

```bash
litellm --model huggingface/bigcode/starcoder
```

This command starts the server on http://0.0.0.0:4000, ready to accept requests.

### Configuring the Proxy
The proxy can be configured with various options:

```bash
# With custom port
litellm --model gpt-3.5-turbo --port 8000

# With multiple models
litellm --model gpt-3.5-turbo,claude-2 --api_key your-master-key
```

### Making Requests to the Proxy
Use standard OpenAI SDK clients to make requests to the proxy:

```python
import openai

client = openai.OpenAI(
    api_key="anything",
    base_url="http://0.0.0.0:4000"
)

response = client.chat.completions.create(
    model="gpt-3.5-turbo",
    messages=[{"role": "user", "content": "write a short poem"}]
)
```

The proxy server translates requests to the appropriate provider format and handles response normalization.

**Section sources**
- [README.md](file://README.md#L223-L255)
- [litellm/proxy/proxy_cli.py](file://litellm/proxy/proxy_cli.py#L132-L135)
- [litellm/proxy/proxy_server.py](file://litellm/proxy/proxy_server.py#L1-L200)

## Troubleshooting Common Issues
When getting started with LiteLLM, you may encounter common issues that can be resolved with proper diagnosis and configuration.

### Authentication Errors
Authentication errors typically occur when API keys are missing or incorrect:

```python
# Ensure environment variables are set
import os
os.environ["OPENAI_API_KEY"] = "your-valid-key"

# Or pass directly in the call
response = completion(
    model="openai/gpt-4o",
    messages=messages,
    api_key="your-valid-key"
)
```

### Network Timeouts
Network timeouts can occur due to connectivity issues or slow responses:

```python
# Increase timeout
response = completion(
    model="openai/gpt-4o",
    messages=messages,
    timeout=60  # seconds
)
```

### Model Not Found
Ensure you're using the correct model identifier format:

```python
# Correct format: provider/model_name
response = completion(model="openai/gpt-4o", messages=messages)

# Check supported models in documentation
```

### Proxy Connection Issues
For proxy server issues, verify the server is running and accessible:

```bash
# Check if server is running
curl http://0.0.0.0:4000/health

# Verify port availability
lsof -i :4000
```

**Section sources**
- [README.md](file://README.md#L198-L205)
- [litellm/main.py](file://litellm/main.py#L624-L631)
- [litellm/proxy/proxy_cli.py](file://litellm/proxy/proxy_cli.py#L60-L63)

## Performance Considerations
Optimizing performance is crucial for efficient LLM integration. Consider the following factors when deploying LiteLLM:

- **Connection Pooling**: LiteLLM uses connection pooling to improve performance when making multiple requests.
- **Caching**: Implement response caching to reduce redundant API calls and improve response times.
- **Timeout Configuration**: Set appropriate timeouts based on your application's requirements and network conditions.
- **Async Operations**: Use asynchronous calls for I/O-bound applications to improve throughput.
- **Load Balancing**: When using the proxy server, configure multiple models for failover and load distribution.

Monitor your application's performance and adjust these parameters based on your specific use case and requirements.

**Section sources**
- [README.md](file://README.md#L40-L41)
- [litellm/proxy/proxy_server.py](file://litellm/proxy/proxy_server.py#L33-L39)
- [litellm/main.py](file://litellm/main.py#L446-L447)

## Best Practices
Follow these best practices to ensure secure and efficient use of LiteLLM:

- **Secure API Key Management**: Never hardcode API keys in your source code. Use environment variables or secure secret management systems.
- **Error Handling**: Implement comprehensive error handling to manage API failures and network issues gracefully.
- **Rate Limiting**: Respect provider rate limits and implement appropriate retry logic with exponential backoff.
- **Monitoring and Logging**: Enable logging and monitoring to track usage, costs, and performance metrics.
- **Regular Updates**: Keep LiteLLM updated to benefit from new features, performance improvements, and security patches.
- **Environment Separation**: Use different API keys and configurations for development, testing, and production environments.

Adhering to these practices will help you build robust and maintainable applications using LiteLLM.

**Section sources**
- [README.md](file://README.md#L184-L205)
- [litellm/__init__.py](file://litellm/__init__.py#L103-L189)
- [litellm/main.py](file://litellm/main.py#L470-L492)