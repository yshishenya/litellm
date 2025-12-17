# Enterprise Features

<cite>
**Referenced Files in This Document**   
- [custom_sso_handler.py](file://enterprise/litellm_enterprise/proxy/auth/custom_sso_handler.py#L1-L86)
- [audit_logging_endpoints.py](file://enterprise/litellm_enterprise/proxy/audit_logging_endpoints.py#L1-L168)
- [enterprise_routes.py](file://enterprise/litellm_enterprise/proxy/enterprise_routes.py#L1-L27)
- [callback_controls.py](file://enterprise/litellm_enterprise/enterprise_callbacks/callback_controls.py#L1-L99)
- [SCIM_v2.py](file://litellm/types/proxy/management_endpoints/scim_v2.py#L54-L114)
- [SCIM.tsx](file://ui/litellm-dashboard/src/components/SCIM.tsx#L1-L158)
- [auth_checks.py](file://litellm/proxy/auth/auth_checks.py#L918-L975)
</cite>

## Table of Contents
1. [Introduction](#introduction)
2. [Architecture Overview](#architecture-overview)
3. [SSO Integration](#sso-integration)
4. [SCIM Provisioning](#scim-provisioning)
5. [Audit Logging](#audit-logging)
6. [Role-Based Access Control](#role-based-access-control)
7. [Multi-Tenancy and Organization Hierarchies](#multi-tenancy-and-organization-hierarchies)
8. [Enterprise Callbacks](#enterprise-callbacks)
9. [Security Integration](#security-integration)
10. [Troubleshooting Guide](#troubleshooting-guide)
11. [Performance Considerations](#performance-considerations)
12. [Best Practices](#best-practices)

## Introduction
LiteLLM Enterprise provides a comprehensive suite of features designed for large-scale, secure deployments in enterprise environments. This documentation covers the architecture and implementation details of key enterprise capabilities including Single Sign-On (SSO) integration, System for Cross-domain Identity Management (SCIM) provisioning, audit logging, role-based access control, and multi-tenancy support. The enterprise module is designed to meet the stringent security, compliance, and scalability requirements of large organizations, enabling secure API access management, user provisioning, and comprehensive audit trails.

## Architecture Overview
The LiteLLM Enterprise architecture is built as an extension to the core LiteLLM proxy, providing enterprise-grade features through a modular design. The architecture consists of several key components that work together to provide secure, scalable enterprise functionality.

```mermaid
graph TB
subgraph "Enterprise Features"
SSO[SSO Integration]
SCIM[SCIM Provisioning]
Audit[Audit Logging]
RBAC[Role-Based Access Control]
MultiTenancy[Multi-Tenancy]
Callbacks[Enterprise Callbacks]
end
subgraph "Core Proxy"
Auth[Authentication]
Routing[Request Routing]
KeyManagement[API Key Management]
Prisma[Prisma Client]
end
SSO --> Auth
SCIM --> KeyManagement
Audit --> Prisma
RBAC --> Auth
MultiTenancy --> KeyManagement
Callbacks --> Auth
Auth --> Prisma
KeyManagement --> Prisma
style SSO fill:#f9f,stroke:#333
style SCIM fill:#f9f,stroke:#333
style Audit fill:#f9f,stroke:#333
style RBAC fill:#f9f,stroke:#333
style MultiTenancy fill:#f9f,stroke:#333
style Callbacks fill:#f9f,stroke:#333
```

**Diagram sources**
- [custom_sso_handler.py](file://enterprise/litellm_enterprise/proxy/auth/custom_sso_handler.py#L1-L86)
- [audit_logging_endpoints.py](file://enterprise/litellm_enterprise/proxy/audit_logging_endpoints.py#L1-L168)
- [enterprise_routes.py](file://enterprise/litellm_enterprise/proxy/enterprise_routes.py#L1-L27)

**Section sources**
- [custom_sso_handler.py](file://enterprise/litellm_enterprise/proxy/auth/custom_sso_handler.py#L1-L86)
- [audit_logging_endpoints.py](file://enterprise/litellm_enterprise/proxy/audit_logging_endpoints.py#L1-L168)

## SSO Integration
LiteLLM Enterprise supports custom SSO integration through the EnterpriseCustomSSOHandler class, which enables organizations to integrate with their existing identity providers and OAuth proxies. The SSO integration allows users to authenticate through an external OAuth proxy that has already authenticated the user, extracting user information from custom headers or request attributes.

The SSO flow begins with the handle_custom_ui_sso_sign_in method, which processes incoming requests and converts user information into OpenID format. This approach is particularly useful when deploying LiteLLM behind an existing OAuth proxy, where the proxy has already handled user authentication and added custom headers containing user information.

```mermaid
sequenceDiagram
participant User as "User"
participant OAuthProxy as "OAuth Proxy"
participant LiteLLM as "LiteLLM Proxy"
participant SSOHandler as "EnterpriseCustomSSOHandler"
participant AuthHandler as "SSOAuthenticationHandler"
User->>OAuthProxy : Access LiteLLM UI
OAuthProxy->>OAuthProxy : Authenticate User
OAuthProxy->>LiteLLM : Forward Request with Headers
LiteLLM->>SSOHandler : handle_custom_ui_sso_sign_in()
SSOHandler->>SSOHandler : Extract User Info from Headers
SSOHandler->>SSOHandler : Convert to OpenID Object
SSOHandler->>AuthHandler : get_redirect_response_from_openid()
AuthHandler->>User : Redirect with Authentication Token
```

**Diagram sources**
- [custom_sso_handler.py](file://enterprise/litellm_enterprise/proxy/auth/custom_sso_handler.py#L36-L86)

**Section sources**
- [custom_sso_handler.py](file://enterprise/litellm_enterprise/proxy/auth/custom_sso_handler.py#L1-L86)

## SCIM Provisioning
LiteLLM Enterprise provides SCIM v2.0 compliant provisioning endpoints for automated user and group management. The SCIM integration enables seamless synchronization of user identities and group memberships between identity providers and the LiteLLM proxy, supporting automated provisioning, deprovisioning, and attribute synchronization.

The SCIM implementation includes support for core SCIM resources including users and groups, with standard CRUD operations for managing identities. The system supports the urn:ietf:params:scim:schemas:core:2.0:User and urn:ietf:params:scim:schemas:core:2.0:Group schemas, along with the service provider configuration endpoint that describes supported features.

```mermaid
classDiagram
class SCIMUser {
+schemas List[str]
+id str
+userName str
+name SCIMName
+emails List[SCIMEmail]
+active bool
+meta SCIMMeta
}
class SCIMGroup {
+schemas List[str]
+id str
+displayName str
+members List[SCIMMember]
}
class SCIMMember {
+value str
+display str
}
class SCIMServiceProviderConfig {
+schemas List[str]
+patch SCIMFeature
+bulk SCIMFeature
+filter SCIMFeature
+changePassword SCIMFeature
+sort SCIMFeature
+etag SCIMFeature
}
class SCIMFeature {
+supported bool
+maxOperations int
+maxPayloadSize int
+maxResults int
}
SCIMUser --> SCIMServiceProviderConfig : "supported by"
SCIMGroup --> SCIMServiceProviderConfig : "supported by"
SCIMGroup --> SCIMMember : "contains"
```

**Diagram sources**
- [SCIM_v2.py](file://litellm/types/proxy/management_endpoints/scim_v2.py#L54-L114)
- [SCIM.tsx](file://ui/litellm-dashboard/src/components/SCIM.tsx#L1-L158)

**Section sources**
- [SCIM_v2.py](file://litellm/types/proxy/management_endpoints/scim_v2.py#L54-L114)
- [SCIM.tsx](file://ui/litellm-dashboard/src/components/SCIM.tsx#L1-L158)

## Audit Logging
LiteLLM Enterprise provides comprehensive audit logging capabilities to track all administrative actions and system changes. The audit logging system captures detailed information about who made changes, what was changed, when the change occurred, and which API key was used, enabling compliance with regulatory requirements and security monitoring.

The audit logging endpoints provide both paginated retrieval of audit logs and detailed lookup by ID. Logs are stored in the database with fields for the action performed (create, update, delete), the table modified, the object ID, the user or system that made the change, and the timestamp of the change. The system supports filtering by various criteria including date ranges, action types, table names, and user identifiers.

```mermaid
flowchart TD
Start([Audit Log Request]) --> ValidateAuth["Validate API Key"]
ValidateAuth --> CheckPermissions["Check User Permissions"]
CheckPermissions --> ApplyFilters["Apply Filter Parameters"]
ApplyFilters --> BuildQuery["Build Database Query"]
BuildQuery --> ExecuteQuery["Execute Prisma Query"]
ExecuteQuery --> GetTotal["Get Total Count"]
ExecuteQuery --> GetResults["Get Paginated Results"]
GetTotal --> CalculatePages["Calculate Total Pages"]
CalculatePages --> FormatResponse["Format Response"]
GetResults --> FormatResponse
FormatResponse --> ReturnResponse["Return Paginated Response"]
ReturnResponse --> End([Response Sent])
style Start fill:#f9f,stroke:#333
style End fill:#f9f,stroke:#333
```

**Diagram sources**
- [audit_logging_endpoints.py](file://enterprise/litellm_enterprise/proxy/audit_logging_endpoints.py#L25-L168)

**Section sources**
- [audit_logging_endpoints.py](file://enterprise/litellm_enterprise/proxy/audit_logging_endpoints.py#L1-L168)

## Role-Based Access Control
LiteLLM Enterprise implements a robust role-based access control (RBAC) system that allows administrators to define granular permissions for different user roles. The RBAC system controls access to models, routes, and management endpoints based on user roles, enabling organizations to enforce the principle of least privilege.

The role-based permissions are configured in the general_settings configuration, where administrators can define which models and routes are accessible to each role. The system supports standard roles such as admin, user, and viewer, with configurable permissions that can be customized to meet specific organizational requirements.

```mermaid
graph TD
User[User Role] --> |Check| RBAC[RBAC System]
RBAC --> |Fetch| Permissions[Role Permissions]
Permissions --> |Contains| Models[Allowed Models]
Permissions --> |Contains| Routes[Allowed Routes]
Models --> |Validate| ModelAccess[Model Access Check]
Routes --> |Validate| RouteAccess[Route Access Check]
ModelAccess --> |Allowed| AllowModel[Allow Model Usage]
RouteAccess --> |Allowed| AllowRoute[Allow Route Access]
ModelAccess --> |Denied| DenyModel[Deny Model Usage]
RouteAccess --> |Denied| DenyRoute[Deny Route Access]
style User fill:#f9f,stroke:#333
style AllowModel fill:#9f9,stroke:#333
style AllowRoute fill:#9f9,stroke:#333
style DenyModel fill:#f99,stroke:#333
style DenyRoute fill:#f99,stroke:#333
```

**Diagram sources**
- [auth_checks.py](file://litellm/proxy/auth/auth_checks.py#L918-L975)

**Section sources**
- [auth_checks.py](file://litellm/proxy/auth/auth_checks.py#L918-L975)

## Multi-Tenancy and Organization Hierarchies
LiteLLM Enterprise supports multi-tenancy through organization-based isolation of resources and permissions. The system allows organizations to create hierarchical structures with parent-child relationships between organizations, enabling delegated administration and resource sharing across organizational units.

Each organization has its own set of API keys, users, and configuration settings, with the ability to inherit certain policies from parent organizations. This hierarchical approach enables large enterprises to manage multiple business units or departments with different requirements while maintaining centralized control over security policies and compliance settings.

The multi-tenancy model integrates with the RBAC system, allowing different roles to have different levels of access across organizational boundaries. For example, a global administrator might have access to all organizations, while a department administrator only has access to their specific organizational unit and its children.

## Enterprise Callbacks
LiteLLM Enterprise provides a flexible callback system that allows organizations to extend the proxy's functionality with custom enterprise-specific logic. The callback system supports various types of enterprise callbacks including email notifications, secret detection, and integration with external monitoring systems.

The EnterpriseCallbackControls class provides mechanisms for dynamically enabling or disabling callbacks based on request headers or other conditions. This allows organizations to control which callbacks are executed for specific requests, providing flexibility in how enterprise features are applied.

```mermaid
classDiagram
class EnterpriseCallbackControls {
+is_callback_disabled_dynamically()
+get_disabled_callbacks()
+_should_allow_dynamic_callback_disabling()
}
class CustomLogger {
<<interface>>
+log_event()
+async_log_event()
}
class EmailCallback {
+send_notification()
}
class SecretDetectionCallback {
+scan_for_secrets()
}
class PagerDutyCallback {
+trigger_incident()
}
EnterpriseCallbackControls --> CustomLogger : "controls"
EmailCallback --> CustomLogger : "implements"
SecretDetectionCallback --> CustomLogger : "implements"
PagerDutyCallback --> CustomLogger : "implements"
```

**Diagram sources**
- [callback_controls.py](file://enterprise/litellm_enterprise/enterprise_callbacks/callback_controls.py#L14-L99)

**Section sources**
- [callback_controls.py](file://enterprise/litellm_enterprise/enterprise_callbacks/callback_controls.py#L1-L99)

## Security Integration
LiteLLM Enterprise integrates with various security systems to provide comprehensive protection for API access and data. The security integration includes support for API key management, team-based routing, and encryption of sensitive data.

The system supports the x-litellm-disable-callbacks header, which allows requests to dynamically disable specific callbacks for security or performance reasons. This feature is particularly useful in enterprise environments where certain callbacks might need to be temporarily disabled for specific operations.

The integration between enterprise features and security systems ensures that access controls are consistently enforced across all components. For example, when a user makes a request, the system validates their API key, checks their role-based permissions, and applies any organization-specific policies before routing the request to the appropriate LLM provider.

## Troubleshooting Guide
When implementing LiteLLM Enterprise features, several common issues may arise. This section provides guidance for diagnosing and resolving these issues.

For SSO configuration errors, verify that the OAuth proxy is correctly configured to add the required headers to requests. Check that the custom_ui_sso_sign_in_handler is properly configured in the general_settings and that it can successfully extract user information from the request headers.

For permission inheritance problems in organization hierarchies, ensure that the parent organization's policies are correctly configured and that child organizations are properly linked. Verify that role-based permissions are correctly defined and that there are no conflicting policies.

When audit logs are not being generated, check that the prisma_client is properly connected to the database and that the audit logging endpoints have the necessary permissions to write to the database. Verify that the premium_user flag is set to True, as audit logging is an enterprise feature.

## Performance Considerations
For large organizations with thousands of users, several performance considerations should be addressed. The SCIM provisioning endpoints should be optimized for bulk operations to minimize the number of API calls required for user synchronization. Caching strategies should be implemented for frequently accessed data such as user roles and permissions.

The audit logging system should be configured with appropriate indexing on the database to ensure fast query performance, especially when filtering by date ranges or other common criteria. For organizations with high volumes of audit data, consider implementing data retention policies and archiving older logs to maintain performance.

The RBAC system should be optimized to minimize the overhead of permission checks, particularly for high-traffic endpoints. Caching of role-based permissions can significantly improve performance for organizations with complex permission structures.

## Best Practices
To ensure secure and effective deployment of LiteLLM Enterprise features, follow these best practices:

1. Implement regular key rotation for API keys and service accounts
2. Configure appropriate data retention policies for audit logs
3. Use the principle of least privilege when defining role-based permissions
4. Regularly review and audit access controls and user permissions
5. Implement monitoring and alerting for security-related events
6. Use encryption for sensitive data at rest and in transit
7. Regularly update and patch the LiteLLM proxy and its dependencies
8. Conduct regular security assessments and penetration testing
9. Implement backup and disaster recovery procedures
10. Document and review security policies and procedures regularly