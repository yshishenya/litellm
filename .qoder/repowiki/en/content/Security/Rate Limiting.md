# Rate Limiting

<cite>
**Referenced Files in This Document**   
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py)
- [dynamic_rate_limiter_v3.py](file://litellm/proxy/hooks/dynamic_rate_limiter_v3.py)
- [model_config.yaml](file://litellm/proxy/model_config.yaml)
- [proxy_server.py](file://litellm/proxy/proxy_server.py)
- [user_api_key_auth.py](file://litellm/proxy/auth/user_api_key_auth.py)
- [budget_manager.py](file://litellm/budget_manager.py)
- [README.dynamic_rate_limiter_v3.md](file://litellm/proxy/hooks/README.dynamic_rate_limiter_v3.md)
</cite>

## Table of Contents
1. [Introduction](#introduction)
2. [Rate Limiting Architecture](#rate-limiting-architecture)
3. [Global Rate Limits](#global-rate-limits)
4. [Per-Key Rate Limits](#per-key-rate-limits)
5. [Team-Based Rate Limiting](#team-based-rate-limiting)
6. [Dynamic Rate Limiting Implementation](#dynamic-rate-limiting-implementation)
7. [Configuration Options](#configuration-options)
8. [Relationship with Authentication and Budget Management](#relationship-with-authentication-and-budget-management)
9. [Common Issues and Solutions](#common-issues-and-solutions)
10. [Performance Considerations](#performance-considerations)
11. [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)

## Introduction

LiteLLM's rate limiting system provides comprehensive request throttling capabilities designed to manage API usage across various dimensions including global, per-key, and team-based limits. The system implements both RPM (requests per minute) and TPM (tokens per minute) limits using Redis and in-memory stores for distributed rate limiting in clustered environments. This documentation details the architecture, configuration, and implementation of LiteLLM's rate limiting sub-feature, providing guidance for deployment and optimization.

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L1-L100)
- [dynamic_rate_limiter_v3.py](file://litellm/proxy/hooks/dynamic_rate_limiter_v3.py#L1-L50)

## Rate Limiting Architecture

LiteLLM's rate limiting architecture is built around a hierarchical system of descriptors that define rate limits at different levels of granularity. The system uses Redis for distributed rate limiting across clustered environments, with fallback to in-memory caching when Redis is unavailable. The architecture follows a two-phase approach: first checking limits in read-only mode, then enforcing them if necessary.

```mermaid
graph TD
A[Incoming Request] --> B[Check Model Saturation]
B --> C{Saturation Level}
C --> |< 80%| D[Generous Mode]
C --> |>= 80%| E[Strict Mode]
D --> F[Enforce Model-wide Capacity]
D --> G[First-come-first-served]
E --> H[Normalize Priority Weights]
E --> I[Enforce Strict Limits]
F --> J[v3 Limiter Check]
G --> J
H --> J
I --> J
J --> K{OVER_LIMIT?}
K --> |Yes| L[Return 429 Error]
K --> |No| M[Allow Request]
```

**Diagram sources**
- [README.dynamic_rate_limiter_v3.md](file://litellm/proxy/hooks/README.dynamic_rate_limiter_v3.md#L15-L77)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L448-L463)
- [dynamic_rate_limiter_v3.py](file://litellm/proxy/hooks/dynamic_rate_limiter_v3.py#L434-L458)

## Global Rate Limits

Global rate limits in LiteLLM are applied at the organization level and provide a top-level constraint on API usage. These limits are configured through the UserAPIKeyAuth object and can be set for both RPM and TPM. The system checks organization-wide limits before processing individual requests, ensuring that no single organization can exceed its allocated quota.

Global limits are implemented using Redis counters with sliding window algorithms to provide accurate rate tracking. The system supports both hard limits (which immediately reject requests when exceeded) and soft limits (which allow temporary bursts within defined parameters).

```mermaid
classDiagram
class RateLimitDescriptor {
+string key
+string value
+RateLimitObject rate_limit
}
class RateLimitObject {
+int requests_per_unit
+int tokens_per_unit
+int max_parallel_requests
+int window_size
}
class RateLimitResponse {
+string overall_code
+RateLimitStatus[] statuses
}
class RateLimitStatus {
+string code
+int current_limit
+int limit_remaining
+string rate_limit_type
+string descriptor_key
}
RateLimitDescriptor --> RateLimitObject : "contains"
RateLimitResponse --> RateLimitStatus : "contains"
```

**Diagram sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L115-L139)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L591-L611)
- [user_api_key_auth.py](file://litellm/proxy/auth/user_api_key_auth.py#L638-L656)

## Per-Key Rate Limits

Per-key rate limits in LiteLLM provide granular control over API usage for individual API keys. These limits can be configured for both RPM and TPM and are enforced at the key level. The system supports model-specific rate limits, allowing different limits to be set for different models accessed through the same API key.

The implementation uses Redis hash tags to ensure that all rate limit counters for a given key are stored on the same Redis node in a cluster environment. This prevents cross-node operations and ensures atomicity of rate limit checks and updates.

```mermaid
sequenceDiagram
participant Client as "Client App"
participant Proxy as "LiteLLM Proxy"
participant Redis as "Redis Cluster"
Client->>Proxy : API Request with Key
Proxy->>Redis : Check key : {key_id} : window
Redis-->>Proxy : Window start time
Proxy->>Redis : Check key : {key_id} : requests
Redis-->>Proxy : Current request count
Proxy->>Redis : Check key : {key_id} : tokens
Redis-->>Proxy : Current token count
Proxy->>Proxy : Calculate remaining limits
alt Within Limits
Proxy-->>Client : Process Request
else Over Limit
Proxy-->>Client : 429 Rate Limit Exceeded
end
```

**Diagram sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L472-L483)
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L841-L856)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L668-L727)
- [custom_auth.md](file://docs/my-website/docs/proxy/custom_auth.md#L70-L88)

## Team-Based Rate Limiting

Team-based rate limiting in LiteLLM allows organizations to allocate quotas to teams and individual team members. This hierarchical approach enables fine-grained control over API usage across different teams and members within an organization. The system supports team-level limits, team member limits, and end-user limits.

Team-based limits are implemented using composite keys that combine team ID and user ID. This allows the system to enforce both team-wide limits and per-member limits simultaneously. The implementation also supports end-user tracking, enabling rate limits to be applied at the end-user level regardless of which API key is used.

```mermaid
flowchart TD
A[Request] --> B{Has Team ID?}
B --> |Yes| C[Check Team Limits]
B --> |No| D[Skip Team Limits]
C --> E{Team Over Limit?}
E --> |Yes| F[Reject Request]
E --> |No| G[Check Member Limits]
G --> H{Member Over Limit?}
H --> |Yes| F
H --> |No| I[Check End User Limits]
I --> J{End User Over Limit?}
J --> |Yes| F
J --> |No| K[Allow Request]
D --> K
```

**Diagram sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L858-L910)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L841-L910)
- [custom_auth.md](file://docs/my-website/docs/proxy/custom_auth.md#L91-L101)

## Dynamic Rate Limiting Implementation

LiteLLM's dynamic rate limiting system uses Redis and Lua scripts to provide high-performance, distributed rate limiting. The implementation uses a sliding window algorithm with Redis counters to track usage over time. The system supports both in-memory and Redis-based storage, with automatic fallback to in-memory caching when Redis is unavailable.

The dynamic rate limiter uses a two-phase approach: first checking limits in read-only mode, then enforcing them if necessary. This prevents unnecessary counter increments when a request would be rejected anyway. The system also supports priority-based rate limiting, allowing certain keys to reserve capacity even when the system is under heavy load.

```mermaid
graph TB
subgraph "Redis Operations"
A[Batch Get Keys] --> B[Group by Hash Tag]
B --> C[Execute Lua Script]
C --> D[Handle Cluster Compatibility]
D --> E[Fallback to In-Memory]
end
subgraph "Rate Limit Logic"
F[Collect Descriptors] --> G[Check Read-Only]
G --> H{Over Limit?}
H --> |Yes| I[Return 429]
H --> |No| J[Increment Counters]
J --> K[Allow Request]
end
A --> F
E --> G
```

**Diagram sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L406-L446)
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L448-L463)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L406-L483)
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L448-L463)

## Configuration Options

Rate limiting in LiteLLM can be configured through both the model_config.yaml file and the management API. The configuration supports RPM and TPM limits at multiple levels: global, per-key, per-team, and per-model. The system also supports different rate limiting modes including guaranteed throughput, best effort, and dynamic.

Configuration options include:
- RPM (requests per minute) limits
- TPM (tokens per minute) limits
- Max parallel requests
- Window size for rate limiting
- Priority-based reservations
- Burst handling parameters

```mermaid
erDiagram
USER_API_KEY ||--o{ RATE_LIMIT : has
TEAM ||--o{ RATE_LIMIT : has
MODEL ||--o{ RATE_LIMIT : has
ORGANIZATION ||--o{ RATE_LIMIT : has
RATE_LIMIT {
string limit_type PK
int rpm_limit
int tpm_limit
int max_parallel_requests
int window_size
string priority
timestamp created_at
timestamp updated_at
}
USER_API_KEY {
string key_id PK
string org_id FK
string team_id FK
timestamp created_at
timestamp updated_at
}
TEAM {
string team_id PK
string org_id FK
float max_budget
string budget_duration
timestamp created_at
timestamp updated_at
}
MODEL {
string model_name PK
string model_id
int rpm_limit
int tpm_limit
timestamp created_at
timestamp updated_at
}
ORGANIZATION {
string org_id PK
float max_budget
string budget_duration
timestamp created_at
timestamp updated_at
}
```

**Diagram sources**
- [model_config.yaml](file://litellm/proxy/model_config.yaml#L1-L11)
- [proxy_server.py](file://litellm/proxy/proxy_server.py#L1-L200)

**Section sources**
- [model_config.yaml](file://litellm/proxy/model_config.yaml#L1-L11)
- [proxy_server.py](file://litellm/proxy/proxy_server.py#L1-L200)
- [RateLimitTypeFormItem.tsx](file://ui/litellm-dashboard/src/components/common_components/RateLimitTypeFormItem.tsx#L80-L110)

## Relationship with Authentication and Budget Management

Rate limiting in LiteLLM is tightly integrated with the authentication system and budget management. The UserAPIKeyAuth object contains all rate limit information, linking authentication credentials directly to usage limits. This integration allows for per-user, per-team, and per-organization rate limits to be enforced based on authentication tokens.

The system also integrates with budget management, allowing rate limits to be adjusted based on remaining budget. When a user or team approaches their budget limit, rate limits can be automatically tightened to prevent overspending. This creates a cohesive system where rate limiting and budget management work together to control API usage.

```mermaid
classDiagram
class UserAPIKeyAuth {
+string api_key
+string user_id
+string team_id
+string org_id
+int tpm_limit
+int rpm_limit
+int user_tpm_limit
+int user_rpm_limit
+int team_tpm_limit
+int team_rpm_limit
+int team_member_tpm_limit
+int team_member_rpm_limit
+int end_user_tpm_limit
+int end_user_rpm_limit
+float max_budget
+string budget_duration
}
class BudgetManager {
+string project_name
+string client_type
+dict user_dict
+create_budget(user, total_budget, duration)
+update_cost(user, completion_obj)
+get_current_cost(user)
+reset_cost(user)
+reset_on_duration(user)
}
class RateLimiter {
+int window_size
+DualCache internal_usage_cache
+should_rate_limit(descriptors)
+check_key_in_limits(user_api_key_dict)
}
UserAPIKeyAuth --> RateLimiter : "provides limits"
UserAPIKeyAuth --> BudgetManager : "provides budget"
RateLimiter --> BudgetManager : "checks budget"
```

**Diagram sources**
- [user_api_key_auth.py](file://litellm/proxy/auth/user_api_key_auth.py#L638-L656)
- [budget_manager.py](file://litellm/budget_manager.py#L1-L231)

**Section sources**
- [user_api_key_auth.py](file://litellm/proxy/auth/user_api_key_auth.py#L638-L656)
- [budget_manager.py](file://litellm/budget_manager.py#L1-L231)
- [spend_management_endpoints.py](file://litellm/proxy/spend_tracking/spend_management_endpoints.py#L2844-L2876)

## Common Issues and Solutions

Common issues with rate limiting in LiteLLM include burst handling, distributed rate limiting in clustered environments, and monitoring rate limit violations. The system addresses these issues through several mechanisms:

1. **Burst Handling**: The sliding window algorithm allows for controlled bursts within defined limits. The system calculates remaining limits based on the current window, allowing requests to be processed as long as they don't exceed the window's capacity.

2. **Distributed Rate Limiting**: In clustered environments, the system uses Redis hash tags to ensure that all rate limit counters for a given key are stored on the same Redis node. This prevents cross-node operations and ensures atomicity.

3. **Monitoring Violations**: The system provides detailed error messages when rate limits are exceeded, including information about which limit was exceeded and the current usage. This helps users understand and resolve rate limit issues.

```mermaid
flowchart TD
A[Rate Limit Error] --> B{Error Type}
B --> |RPM Exceeded| C[Check Request Count]
B --> |TPM Exceeded| D[Check Token Count]
B --> |Parallel Requests| E[Check Concurrent Requests]
C --> F[Return 429 with RPM Details]
D --> G[Return 429 with TPM Details]
E --> H[Return 429 with Parallel Details]
F --> I[Include Reset Time]
G --> I
H --> I
I --> J[Log Violation]
J --> K[Update Monitoring Metrics]
```

**Diagram sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L314-L354)
- [batch_rate_limiter.py](file://litellm/proxy/hooks/batch_rate_limiter.py#L107-L134)

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L314-L354)
- [batch_rate_limiter.py](file://litellm/proxy/hooks/batch_rate_limiter.py#L107-L134)
- [dynamic_rate_limit.md](file://docs/my-website/docs/proxy/dynamic_rate_limit.md#L288-L306)

## Performance Considerations

Performance considerations for LiteLLM's rate limiting system include optimizing Redis operations, minimizing latency, and handling high-throughput scenarios. The system uses several techniques to ensure high performance:

1. **Batch Operations**: The system batches Redis operations to reduce network overhead and improve throughput.
2. **Lua Scripts**: Complex rate limit calculations are performed in Redis using Lua scripts, reducing round-trip times.
3. **In-Memory Fallback**: When Redis is unavailable, the system falls back to in-memory caching to maintain availability.
4. **Connection Pooling**: The system uses connection pooling to minimize the overhead of establishing Redis connections.

For high-throughput systems, it's recommended to tune the window size and use Redis clusters to distribute the load. The system also supports priority-based rate limiting, which can help ensure that critical requests are processed even under heavy load.

**Section sources**
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L406-L446)
- [parallel_request_limiter_v3.py](file://litellm/proxy/hooks/parallel_request_limiter_v3.py#L92-L108)

## Monitoring and Troubleshooting

Monitoring and troubleshooting rate limiting in LiteLLM involves tracking key metrics, analyzing error patterns, and using the provided diagnostic tools. The system provides several mechanisms for monitoring rate limit usage:

1. **Rate Limit Headers**: The system includes rate limit information in response headers, showing remaining requests and tokens.
2. **Detailed Error Messages**: When rate limits are exceeded, the system provides detailed error messages explaining which limit was exceeded.
3. **Prometheus Metrics**: The system exports rate limit metrics to Prometheus for monitoring and alerting.
4. **Logging**: Detailed logs are available to track rate limit checks and violations.

Troubleshooting common issues involves checking Redis connectivity, verifying configuration settings, and analyzing usage patterns. The system's modular design makes it easy to isolate and resolve rate limiting issues.

**Section sources**
- [router.py](file://litellm/router.py#L6652-L6680)
- [team_info.tsx](file://ui/litellm-dashboard/src/components/team/team_info.tsx#L523-L551)
- [dynamic_rate_limit.md](file://docs/my-website/docs/proxy/dynamic_rate_limit.md#L288-L306)