# Deployment

<cite>
**Referenced Files in This Document**   
- [Dockerfile](file://Dockerfile)
- [docker/Dockerfile.alpine](file://docker/Dockerfile.alpine)
- [docker/Dockerfile.dev](file://docker/Dockerfile.dev)
- [docker/Dockerfile.non_root](file://docker/Dockerfile.non_root)
- [docker/Dockerfile.custom_ui](file://docker/Dockerfile.custom_ui)
- [docker/Dockerfile.database](file://docker/Dockerfile.database)
- [docker-compose.yml](file://docker-compose.yml)
- [deploy/charts/litellm-helm/Chart.yaml](file://deploy/charts/litellm-helm/Chart.yaml)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml)
- [deploy/charts/litellm-helm/templates/deployment.yaml](file://deploy/charts/litellm-helm/templates/deployment.yaml)
- [deploy/charts/litellm-helm/templates/service.yaml](file://deploy/charts/litellm-helm/templates/service.yaml)
- [deploy/kubernetes/service.yaml](file://deploy/kubernetes/service.yaml)
- [prometheus.yml](file://prometheus.yml)
- [grafana/provisioning/dashboards/teams-optimized.json](file://grafana/provisioning/dashboards/teams-optimized.json)
- [grafana/provisioning/dashboards/teams-simple.json](file://grafana/provisioning/dashboards/teams-simple.json)
- [scripts/backup.sh](file://scripts/backup.sh)
- [scripts/restore.sh](file://scripts/restore.sh)
- [scripts/sync-backups.sh](file://scripts/sync-backups.sh)
</cite>

## Table of Contents
1. [Docker-Based Deployment](#docker-based-deployment)
2. [Kubernetes Deployment with Helm](#kubernetes-deployment-with-helm)
3. [Monitoring and Observability](#monitoring-and-observability)
4. [Production Best Practices](#production-best-practices)
5. [Deployment Configuration Examples](#deployment-configuration-examples)
6. [Operational Requirements](#operational-requirements)

## Docker-Based Deployment

LiteLLM provides multiple Dockerfile variants to support different deployment scenarios and requirements. The primary Dockerfile uses a multi-stage build process with Chainguard Wolfi base images for enhanced security and minimal footprint. This build process separates the build and runtime stages, ensuring that only necessary components are included in the final image.

The repository includes several specialized Dockerfile variants for different use cases:
- **Dockerfile.alpine**: Based on Alpine Linux for minimal image size
- **Dockerfile.dev**: Optimized for development with improved layer caching
- **Dockerfile.non_root**: Security-focused variant that runs as non-root user
- **Dockerfile.custom_ui**: For custom UI deployments with configurable base paths
- **Dockerfile.database**: Includes database dependencies for standalone deployments

The Docker build process incorporates several optimization techniques, including wheel-based dependency installation, Prisma client generation, and Admin UI compilation. The runtime environment uses supervisor for process management and includes health check endpoints for container orchestration.

For local development and testing, the docker-compose.yml file provides a complete environment with LiteLLM proxy, PostgreSQL database, Redis cache, Prometheus, and Grafana. This configuration enables rapid setup of a full-stack deployment with monitoring capabilities.

**Section sources**
- [Dockerfile](file://Dockerfile#L1-L84)
- [docker/Dockerfile.alpine](file://docker/Dockerfile.alpine#L1-L57)
- [docker/Dockerfile.dev](file://docker/Dockerfile.dev#L1-L90)
- [docker-compose.yml](file://docker-compose.yml#L1-L169)

## Kubernetes Deployment with Helm

LiteLLM offers a comprehensive Helm chart for Kubernetes deployments, located in deploy/charts/litellm-helm/. The Helm chart provides a production-ready configuration with support for high availability, autoscaling, and integrated database management.

The Helm chart architecture includes:
- Deployment with configurable replica count
- Service with multiple port exposure options
- ConfigMap for proxy configuration
- Secrets management for master key and database credentials
- Optional PostgreSQL and Redis subcharts
- Horizontal Pod Autoscaler (HPA) for dynamic scaling
- Pod Disruption Budget (PDB) for maintenance operations
- ServiceMonitor for Prometheus metrics collection
- Ingress configuration for external access

The values.yaml file exposes extensive configuration options for resource management, including CPU and memory limits, node affinity, tolerations, and topology spread constraints. The chart supports both standalone database deployment via subchart and connection to existing PostgreSQL instances.

For high availability deployments, the Helm chart can be configured with multiple replicas and autoscaling based on CPU utilization. The deployment template includes liveness, readiness, and startup probes to ensure service reliability. Database schema migrations are handled through a dedicated job that runs on deployment, ensuring database consistency across versions.

**Section sources**
- [deploy/charts/litellm-helm/Chart.yaml](file://deploy/charts/litellm-helm/Chart.yaml#L1-L38)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L1-L299)
- [deploy/charts/litellm-helm/templates/deployment.yaml](file://deploy/charts/litellm-helm/templates/deployment.yaml#L1-L229)
- [deploy/charts/litellm-helm/templates/service.yaml](file://deploy/charts/litellm-helm/templates/service.yaml#L1-L23)
- [deploy/kubernetes/service.yaml](file://deploy/kubernetes/service.yaml#L1-L12)

## Monitoring and Observability

LiteLLM provides comprehensive monitoring capabilities through Prometheus and Grafana integration. The deployment includes a complete observability stack with pre-configured dashboards and metrics collection.

The monitoring architecture consists of:
- Prometheus server for metrics collection and storage
- Grafana for visualization and dashboarding
- Custom metrics exporter for database metrics
- Pre-configured Grafana dashboards for different use cases

The prometheus.yml configuration defines scrape jobs for both the LiteLLM metrics exporter and Prometheus self-monitoring. It includes retention policies with tiered storage based on metric importance, ensuring efficient storage utilization while preserving critical metrics.

Two primary Grafana dashboards are provided:
- **teams-optimized.json**: Comprehensive dashboard with team-level metrics, spend tracking, and performance analysis
- **teams-simple.json**: Simplified dashboard focusing on essential metrics like request volume, latency, and error rates

The metrics collection includes key performance indicators such as:
- Request volume and success rates
- Latency and response times
- Token usage and cost metrics
- Cache hit ratios
- Database performance
- System resource utilization

The monitoring stack supports long-term retention of critical metrics while optimizing storage for high-cardinality data. Remote write configuration is available for integration with long-term storage solutions like Thanos.

**Section sources**
- [prometheus.yml](file://prometheus.yml#L1-L54)
- [grafana/provisioning/dashboards/teams-optimized.json](file://grafana/provisioning/dashboards/teams-optimized.json)
- [grafana/provisioning/dashboards/teams-simple.json](file://grafana/provisioning/dashboards/teams-simple.json)
- [docker-compose.yml](file://docker-compose.yml#L60-L73)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L282-L299)

## Production Best Practices

For production deployments of LiteLLM, several best practices should be followed to ensure reliability, security, and maintainability.

### Backup and Recovery
The repository includes scripts for backup and restore operations:
- **backup.sh**: Creates database backups with timestamped filenames
- **restore.sh**: Restores from backup files with validation
- **sync-backups.sh**: Synchronizes backups to remote storage

Regular backups should be scheduled and stored in geographically distributed locations. The backup strategy should include both database dumps and configuration files to enable complete system restoration.

### Update Procedures
When updating LiteLLM deployments, follow a rolling update strategy to minimize downtime:
1. Test updates in a staging environment
2. Deploy to a canary instance first
3. Monitor metrics and error rates
4. Gradually roll out to production instances
5. Maintain rollback capability

The Helm chart's migration job ensures database schema compatibility during updates, with configurable retry policies and backoff limits.

### Disaster Recovery
A comprehensive disaster recovery plan should include:
- Multi-region deployment with active-passive or active-active configuration
- Automated failover mechanisms
- Regular disaster recovery testing
- Documented recovery procedures
- Communication protocols

The deployment should be designed with infrastructure as code principles, enabling rapid recreation of the entire environment from configuration files.

**Section sources**
- [scripts/backup.sh](file://scripts/backup.sh)
- [scripts/restore.sh](file://scripts/restore.sh)
- [scripts/sync-backups.sh](file://scripts/sync-backups.sh)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L230-L249)
- [docker-compose.yml](file://docker-compose.yml#L130-L158)

## Deployment Configuration Examples

### Development Environment
For local development, use the docker-compose.yml configuration with minimal resource requirements:
```yaml
replicaCount: 1
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

This configuration includes all components (LiteLLM, PostgreSQL, Redis, Prometheus, Grafana) for a complete local development environment.

### Staging Environment
For staging deployments, configure moderate scaling with enhanced monitoring:
```yaml
replicaCount: 2
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "1000m"
```

Enable detailed logging and comprehensive monitoring for thorough testing.

### Production Environment
For production deployments, implement high availability and robust resource management:
```yaml
replicaCount: 3
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 60
pdb:
  enabled: true
  minAvailable: 2
resources:
  requests:
    memory: "4Gi"
    cpu: "2000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

Configure external PostgreSQL and Redis instances for improved performance and reliability. Implement network policies and security controls appropriate for production workloads.

**Section sources**
- [docker-compose.yml](file://docker-compose.yml#L1-L169)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L5-L299)

## Operational Requirements

### High Availability
To achieve high availability, deploy LiteLLM with multiple replicas across different availability zones. Configure the Helm chart with:
- Multiple replicas (minimum 3)
- Pod Disruption Budget to ensure minimum availability during maintenance
- Topology spread constraints for even distribution
- Health checks for automatic failure detection

The deployment should include redundant database and cache instances with automatic failover capabilities.

### Scalability
LiteLLM supports horizontal scaling through Kubernetes HPA and vertical scaling through resource allocation. For high-traffic deployments:
- Enable autoscaling based on CPU and custom metrics
- Configure appropriate resource requests and limits
- Use external Redis for distributed caching
- Implement database read replicas for query load distribution

The architecture supports both synchronous and asynchronous processing patterns to handle varying load patterns.

### Security
Production deployments should implement comprehensive security measures:
- Use non-root containers where possible
- Implement network policies to restrict traffic
- Use secrets management for sensitive configuration
- Enable TLS for external communications
- Implement authentication and authorization controls
- Regular security scanning and vulnerability management

The Dockerfile.non_root variant provides a security-hardened container that runs as a non-root user with minimal privileges.

**Section sources**
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L39-L47)
- [deploy/charts/litellm-helm/values.yaml](file://deploy/charts/litellm-helm/values.yaml#L172-L176)
- [docker/Dockerfile.non_root](file://docker/Dockerfile.non_root#L1-L184)
- [deploy/charts/litellm-helm/templates/deployment.yaml](file://deploy/charts/litellm-helm/templates/deployment.yaml#L155-L168)