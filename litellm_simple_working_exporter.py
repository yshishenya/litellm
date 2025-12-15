#!/usr/bin/env python3
"""
LiteLLM Metrics Exporter с Redis Checkpoint
Версия 2.0 - Hybrid подход с полной загрузкой истории

Особенности:
- Загружает ВСЮ историю из LiteLLM_DailyTeamSpend при первом запуске
- Сохраняет checkpoint в Redis каждые 5 минут
- Восстанавливает состояние из Redis при перезапуске
- Fallback на PostgreSQL если Redis недоступен
- Исправленный SQL для time patterns
- Graceful shutdown с сохранением checkpoint
"""

import os
import time
import signal
import sys
import logging
from datetime import datetime, timedelta
import psycopg2
from psycopg2.extras import RealDictCursor
from prometheus_client import start_http_server, Gauge, Counter
from prometheus_client.core import CollectorRegistry

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Database settings
DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_PORT = os.getenv('DB_PORT', '5433')
DB_USER = os.getenv('DB_USER', 'llmproxy')
DB_PASSWORD = os.getenv('DB_PASSWORD', 'dbpassword9090')
DB_NAME = os.getenv('DB_NAME', 'litellm')

# Redis settings
REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', '6379'))
REDIS_DB = int(os.getenv('REDIS_DB', '0'))

# Exporter settings
METRICS_PORT = int(os.getenv('METRICS_PORT', '9090'))
SCRAPE_INTERVAL = int(os.getenv('SCRAPE_INTERVAL', '60'))
CHECKPOINT_INTERVAL = int(os.getenv('CHECKPOINT_INTERVAL', '300'))  # 5 минут
ENABLE_CHECKPOINT = os.getenv('ENABLE_CHECKPOINT', 'true').lower() == 'true'
HISTORY_DAYS = int(os.getenv('HISTORY_DAYS', '365'))  # Загружать всю историю

# Create custom registry
registry = CollectorRegistry()

# All metrics as Counters for proper Grafana increase() support
litellm_spend_usd = Counter(
    'litellm_spend_usd_total',
    'LiteLLM spending in USD (cumulative)',
    ['team_id', 'team_alias', 'end_user_id', 'end_user_alias', 'model', 'provider'],
    registry=registry
)

litellm_requests_total = Counter(
    'litellm_requests_total',
    'Total LiteLLM requests (cumulative)',
    ['team_id', 'team_alias', 'end_user_id', 'end_user_alias', 'model', 'provider', 'status'],
    registry=registry
)

litellm_tokens_total = Counter(
    'litellm_tokens_total',
    'Total tokens processed (cumulative)',
    ['team_id', 'team_alias', 'end_user_id', 'end_user_alias', 'model', 'provider', 'token_type'],
    registry=registry
)

# Time-based metrics for heatmaps
litellm_requests_by_time_total = Gauge(
    'litellm_requests_by_time_total',
    'Requests aggregated by time patterns',
    ['team_id', 'team_alias', 'end_user_id', 'end_user_alias', 'hour_of_day', 'day_name'],
    registry=registry
)

# Performance metrics
litellm_request_duration_seconds = Gauge(
    'litellm_request_duration_seconds',
    'Average request duration in seconds',
    ['team_id', 'team_alias', 'model', 'provider'],
    registry=registry
)

litellm_tokens_per_second = Gauge(
    'litellm_tokens_per_second',
    'Token generation speed (tokens/second)',
    ['team_id', 'team_alias', 'model', 'provider'],
    registry=registry
)

# Budget and financial metrics
litellm_team_budget_usd = Gauge(
    'litellm_team_budget_usd',
    'Team budget status and usage',
    ['team_id', 'team_alias', 'metric_type'],
    registry=registry
)

litellm_cost_efficiency = Gauge(
    'litellm_cost_efficiency',
    'Cost efficiency metrics',
    ['team_id', 'team_alias', 'end_user_id', 'end_user_alias', 'model', 'provider', 'metric_type'],
    registry=registry
)

# Exporter health metrics
exporter_last_export_timestamp = Gauge(
    'litellm_exporter_last_export_timestamp',
    'Timestamp of last successful export',
    registry=registry
)

exporter_checkpoint_age_seconds = Gauge(
    'litellm_exporter_checkpoint_age_seconds',
    'Age of the last checkpoint in seconds',
    registry=registry
)


class RedisCheckpointManager:
    """Manages checkpoint state in Redis with fallback"""

    def __init__(self):
        self.redis_available = False
        self.redis_client = None

        if ENABLE_CHECKPOINT:
            try:
                import redis
                self.redis_client = redis.Redis(
                    host=REDIS_HOST,
                    port=REDIS_PORT,
                    db=REDIS_DB,
                    decode_responses=True,
                    socket_timeout=5,
                    socket_connect_timeout=5
                )
                self.redis_client.ping()
                self.redis_available = True
                logger.info(f"✓ Redis checkpoint enabled: {REDIS_HOST}:{REDIS_PORT}")
            except Exception as e:
                logger.warning(f"Redis unavailable: {e}. Using fallback mode.")
                self.redis_available = False
        else:
            logger.info("Checkpoint disabled via ENABLE_CHECKPOINT=false")

    def get_last_export_time(self):
        """Retrieve the last export time from Redis or return None if unavailable."""
        if not self.redis_available:
            return None

        try:
            timestamp_str = self.redis_client.get('litellm:exporter:last_export_time')
            if timestamp_str:
                checkpoint_time = datetime.fromisoformat(timestamp_str)
                logger.info(f"✓ Restored checkpoint from Redis: {checkpoint_time}")
                return checkpoint_time
        except Exception as e:
            logger.error(f"Failed to load checkpoint: {e}")

        return None

    def save_checkpoint(self, export_time: datetime):
        """Save checkpoint to Redis."""
        if not self.redis_available:
            return

        try:
            self.redis_client.set(
                'litellm:exporter:last_export_time',
                export_time.isoformat()
            )
            self.redis_client.set(
                'litellm:exporter:last_checkpoint_timestamp',
                datetime.now().isoformat()
            )
            logger.debug(f"✓ Checkpoint saved: {export_time}")

            # Update age metric
            age = (datetime.now() - export_time).total_seconds()
            exporter_checkpoint_age_seconds.set(age)

        except Exception as e:
            logger.error(f"Failed to save checkpoint: {e}")


class LiteLLMMetricsExporter:
    def __init__(self):
        self.connection = None
        self.checkpoint_manager = RedisCheckpointManager()
        self.last_export_time = None
        self.initialized = False

        self.connect_to_db()

        # Determine initialization strategy
        checkpoint_time = self.checkpoint_manager.get_last_export_time()

        # Load full history if no checkpoint or checkpoint is too old
        if checkpoint_time is None:
            logger.info("No checkpoint found, loading full history...")
            self.load_full_history_from_daily_table()
        else:
            time_since_checkpoint = datetime.now() - checkpoint_time
            if time_since_checkpoint > timedelta(hours=2):
                logger.info(f"Checkpoint too old ({time_since_checkpoint}), loading full history...")
                self.load_full_history_from_daily_table()
            else:
                logger.info(f"Using checkpoint from {checkpoint_time}")
                self.load_delta(checkpoint_time)

        self.last_export_time = datetime.now()
        self.initialized = True

    def connect_to_db(self):
        """Connect to PostgreSQL database."""
        try:
            self.connection = psycopg2.connect(
                host=DB_HOST,
                port=DB_PORT,
                user=DB_USER,
                password=DB_PASSWORD,
                database=DB_NAME,
                cursor_factory=RealDictCursor
            )
            logger.info("✓ Connected to PostgreSQL")
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            raise

    def execute_query(self, query, params=None):
        """Execute a SQL query with error handling."""
        try:
            with self.connection.cursor() as cursor:
                cursor.execute(query, params)
                return cursor.fetchall()
        except Exception as e:
            logger.error(f"Query failed: {e}")
            logger.error(f"Query: {query[:200]}...")
            self.connection.rollback()
            return []

    def load_full_history_from_daily_table(self):
        """Load all historical data from LiteLLM_DailyTeamSpend.
        
        This function retrieves aggregated historical data from the
        LiteLLM_DailyTeamSpend table, utilizing pre-aggregated daily data for
        efficiency. It executes a SQL query to fetch metrics such as total spend, total
        requests, and token counts, grouped by team and model. The results are then
        used to initialize various metrics for monitoring, including spend, successful
        requests, and failed requests.
        """
        logger.info("=" * 70)
        logger.info("LOADING FULL HISTORY FROM LiteLLM_DailyTeamSpend")
        logger.info("=" * 70)

        start_time = time.time()

        # Use DailyTeamSpend for speed (1000 rows vs 86k rows)
        query = '''
        SELECT
            team_id,
            model,
            custom_llm_provider as provider,
            SUM(spend) as total_spend,
            SUM(api_requests) as total_requests,
            SUM(prompt_tokens) as total_prompt_tokens,
            SUM(completion_tokens) as total_completion_tokens,
            SUM(successful_requests) as successful_requests,
            SUM(failed_requests) as failed_requests,
            MAX(date) as last_date
        FROM "LiteLLM_DailyTeamSpend"
        WHERE date::date >= CURRENT_DATE - INTERVAL '%s days'
        GROUP BY team_id, model, custom_llm_provider
        HAVING SUM(spend) > 0 OR SUM(api_requests) > 0
        '''

        results = self.execute_query(query, (HISTORY_DAYS,))
        logger.info(f"✓ Loaded {len(results)} aggregated metric series")

        # Get team aliases
        team_aliases = self._get_team_aliases()

        # Initialize Counter metrics with aggregated data
        for row in results:
            team_id = str(row['team_id']) if row['team_id'] else 'no_team'
            team_alias = team_aliases.get(team_id, 'no_alias')

            labels = {
                'team_id': team_id,
                'team_alias': team_alias,
                'end_user_id': 'aggregated',
                'end_user_alias': 'aggregated',
                'model': str(row['model']) if row['model'] else 'unknown',
                'provider': str(row['provider']) if row['provider'] else 'unknown'
            }

            # Initialize spend
            if row['total_spend'] and row['total_spend'] > 0:
                litellm_spend_usd.labels(**labels).inc(float(row['total_spend']))

            # Initialize successful requests
            if row['successful_requests'] and row['successful_requests'] > 0:
                request_labels = labels.copy()
                request_labels['status'] = 'success'
                litellm_requests_total.labels(**request_labels).inc(int(row['successful_requests']))

            # Initialize failed requests
            if row['failed_requests'] and row['failed_requests'] > 0:
                request_labels = labels.copy()
                request_labels['status'] = 'failure'
                litellm_requests_total.labels(**request_labels).inc(int(row['failed_requests']))

            # Initialize tokens
            total_tokens = (row['total_prompt_tokens'] or 0) + (row['total_completion_tokens'] or 0)
            if total_tokens > 0:
                litellm_tokens_total.labels(**labels, token_type='total').inc(float(total_tokens))
            if row['total_prompt_tokens'] and row['total_prompt_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='prompt').inc(float(row['total_prompt_tokens']))
            if row['total_completion_tokens'] and row['total_completion_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='completion').inc(float(row['total_completion_tokens']))

        load_time = time.time() - start_time
        logger.info(f"✓ Full history loaded in {load_time:.2f} seconds")
        logger.info("=" * 70)

    def _get_team_aliases(self):
        """Get a mapping of team_id to team_alias."""
        query = 'SELECT team_id, team_alias FROM "LiteLLM_TeamTable"'
        results = self.execute_query(query)
        return {str(row['team_id']): str(row['team_alias']) for row in results if row['team_id']}

    def load_delta(self, since: datetime):
        """Load only new records since the specified checkpoint.
        
        This function retrieves records from the "LiteLLM_SpendLogs" table that have a
        "startTime"  greater than or equal to the provided `since` datetime. It
        performs left joins with the  "LiteLLM_TeamTable" and "LiteLLM_EndUserTable" to
        enrich the data with team and end-user  information. The results are then
        processed to increment various metrics based on the  loaded records.
        
        Args:
            since (datetime): The datetime from which to load new records.
        """
        logger.info(f"Loading delta since {since}")

        query = '''
        SELECT
            COALESCE(sl.team_id, 'no_team') as team_id,
            COALESCE(tt.team_alias, 'no_alias') as team_alias,
            COALESCE(sl.end_user, 'anonymous') as end_user_id,
            COALESCE(eu.alias, COALESCE(sl.end_user, 'anonymous')) as end_user_alias,
            COALESCE(sl.model, 'unknown') as model,
            COALESCE(sl.custom_llm_provider, 'unknown') as provider,
            COALESCE(sl.status, 'unknown') as status,
            sl.spend,
            sl.total_tokens,
            sl.prompt_tokens,
            sl.completion_tokens
        FROM "LiteLLM_SpendLogs" sl
        LEFT JOIN "LiteLLM_TeamTable" tt ON sl.team_id = tt.team_id
        LEFT JOIN "LiteLLM_EndUserTable" eu ON sl.end_user = eu.user_id
        WHERE sl."startTime" >= %s
        '''

        results = self.execute_query(query, [since])
        logger.info(f"✓ Loaded {len(results)} delta records")

        # Increment counters
        for row in results:
            labels = {
                'team_id': str(row['team_id']),
                'team_alias': str(row['team_alias']),
                'end_user_id': str(row['end_user_id']),
                'end_user_alias': str(row['end_user_alias']),
                'model': str(row['model']),
                'provider': str(row['provider'])
            }

            if row['spend'] and row['spend'] > 0:
                litellm_spend_usd.labels(**labels).inc(float(row['spend']))

            request_labels = labels.copy()
            request_labels['status'] = str(row['status'])
            litellm_requests_total.labels(**request_labels).inc(1)

            if row['total_tokens'] and row['total_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='total').inc(float(row['total_tokens']))
            if row['prompt_tokens'] and row['prompt_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='prompt').inc(float(row['prompt_tokens']))
            if row['completion_tokens'] and row['completion_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='completion').inc(float(row['completion_tokens']))

    def export_core_metrics(self):
        """Export new records to Counter metrics since the last export.
        
        This function retrieves new records from the "LiteLLM_SpendLogs" table that
        have been added since the last export time. It executes a SQL query to fetch
        relevant data, including team and user information, and increments various
        metrics based on the retrieved records. The function also updates the last
        export time to the current datetime after processing the records.
        
        Args:
            self: The instance of the class that contains the last_export_time attribute and the
                execute_query method.
        """
        query = '''
        SELECT
            COALESCE(sl.team_id, 'no_team') as team_id,
            COALESCE(tt.team_alias, 'no_alias') as team_alias,
            COALESCE(sl.end_user, 'anonymous') as end_user_id,
            COALESCE(eu.alias, COALESCE(sl.end_user, 'anonymous')) as end_user_alias,
            COALESCE(sl.model, 'unknown') as model,
            COALESCE(sl.custom_llm_provider, 'unknown') as provider,
            COALESCE(sl.status, 'unknown') as status,
            sl.spend,
            sl.total_tokens,
            sl.prompt_tokens,
            sl.completion_tokens
        FROM "LiteLLM_SpendLogs" sl
        LEFT JOIN "LiteLLM_TeamTable" tt ON sl.team_id = tt.team_id
        LEFT JOIN "LiteLLM_EndUserTable" eu ON sl.end_user = eu.user_id
        WHERE sl."startTime" >= %s
        '''

        results = self.execute_query(query, [self.last_export_time])

        if results:
            logger.info(f"Found {len(results)} new records since {self.last_export_time}")

        # Increment counters with new data
        for row in results:
            labels = {
                'team_id': str(row['team_id']),
                'team_alias': str(row['team_alias']),
                'end_user_id': str(row['end_user_id']),
                'end_user_alias': str(row['end_user_alias']),
                'model': str(row['model']),
                'provider': str(row['provider'])
            }

            if row['spend'] and row['spend'] > 0:
                litellm_spend_usd.labels(**labels).inc(float(row['spend']))

            request_labels = labels.copy()
            request_labels['status'] = str(row['status'])
            litellm_requests_total.labels(**request_labels).inc(1)

            if row['total_tokens'] and row['total_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='total').inc(float(row['total_tokens']))
            if row['prompt_tokens'] and row['prompt_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='prompt').inc(float(row['prompt_tokens']))
            if row['completion_tokens'] and row['completion_tokens'] > 0:
                litellm_tokens_total.labels(**labels, token_type='completion').inc(float(row['completion_tokens']))

        # Update last export time
        self.last_export_time = datetime.now()

    def export_time_patterns(self):
        """Export time-based usage patterns - FIXED SQL"""
        litellm_requests_by_time_total._metrics.clear()

        # ИСПРАВЛЕН: добавлены все поля в GROUP BY
        query = '''
        SELECT
            COALESCE(sl.team_id, 'no_team') as team_id,
            COALESCE(tt.team_alias, 'no_alias') as team_alias,
            COALESCE(sl.end_user, 'anonymous') as end_user_id,
            COALESCE(eu.alias, COALESCE(sl.end_user, 'anonymous')) as end_user_alias,
            EXTRACT(HOUR FROM sl."startTime" AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow') as hour_of_day,
            TO_CHAR(sl."startTime" AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow', 'Day') as day_name,
            COUNT(*) as request_count
        FROM "LiteLLM_SpendLogs" sl
        LEFT JOIN "LiteLLM_TeamTable" tt ON sl.team_id = tt.team_id
        LEFT JOIN "LiteLLM_EndUserTable" eu ON sl.end_user = eu.user_id
        WHERE sl."startTime" >= NOW() - INTERVAL '7 days'
        GROUP BY
            sl.team_id,
            tt.team_alias,
            sl.end_user,
            eu.alias,
            EXTRACT(HOUR FROM sl."startTime" AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow'),
            TO_CHAR(sl."startTime" AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow', 'Day')
        HAVING COUNT(*) > 0
        '''

        results = self.execute_query(query)

        for row in results:
            litellm_requests_by_time_total.labels(
                team_id=str(row['team_id']),
                team_alias=str(row['team_alias']),
                end_user_id=str(row['end_user_id']),
                end_user_alias=str(row['end_user_alias']),
                hour_of_day=str(int(row['hour_of_day'])),
                day_name=str(row['day_name']).strip()
            ).set(float(row['request_count']))

    def export_performance_metrics(self):
        """Export performance metrics"""
        litellm_request_duration_seconds._metrics.clear()
        litellm_tokens_per_second._metrics.clear()

        query = '''
        SELECT
            COALESCE(sl.team_id, 'no_team') as team_id,
            COALESCE(tt.team_alias, 'no_alias') as team_alias,
            COALESCE(sl.model, 'unknown') as model,
            COALESCE(sl.custom_llm_provider, 'unknown') as provider,
            COALESCE(AVG(EXTRACT(EPOCH FROM (sl."endTime" - sl."startTime"))), 0) as avg_duration_seconds,
            COALESCE(SUM(sl.total_tokens), 0) as total_tokens,
            COALESCE(SUM(EXTRACT(EPOCH FROM (sl."endTime" - sl."startTime"))), 0) as total_duration_seconds
        FROM "LiteLLM_SpendLogs" sl
        LEFT JOIN "LiteLLM_TeamTable" tt ON sl.team_id = tt.team_id
        WHERE sl."startTime" >= NOW() - INTERVAL '1 hour'
            AND sl."endTime" IS NOT NULL
            AND sl."startTime" IS NOT NULL
            AND sl.total_tokens > 0
        GROUP BY sl.team_id, tt.team_alias, sl.model, sl.custom_llm_provider
        HAVING COUNT(*) >= 3
        '''

        results = self.execute_query(query)

        for row in results:
            labels = {
                'team_id': str(row['team_id']),
                'team_alias': str(row['team_alias']),
                'model': str(row['model']),
                'provider': str(row['provider'])
            }

            litellm_request_duration_seconds.labels(**labels).set(float(row['avg_duration_seconds']))

            if row['total_duration_seconds'] > 0:
                tokens_per_sec = row['total_tokens'] / row['total_duration_seconds']
                litellm_tokens_per_second.labels(**labels).set(float(tokens_per_sec))

    def export_team_budget_metrics(self):
        """Export team budget status metrics."""
        litellm_team_budget_usd._metrics.clear()

        query = '''
        SELECT
            team_id,
            COALESCE(team_alias, 'no_alias') as team_alias,
            COALESCE(max_budget, 0) as max_budget,
            COALESCE(spend, 0) as current_spend
        FROM "LiteLLM_TeamTable"
        WHERE team_id IS NOT NULL
        '''

        results = self.execute_query(query)

        for row in results:
            team_id = str(row['team_id'])
            team_alias = str(row['team_alias'])
            max_budget = float(row['max_budget'])
            current_spend = float(row['current_spend'])

            litellm_team_budget_usd.labels(team_id=team_id, team_alias=team_alias, metric_type='max_budget').set(max_budget)
            litellm_team_budget_usd.labels(team_id=team_id, team_alias=team_alias, metric_type='current_spend').set(current_spend)

            if max_budget > 0:
                remaining = max(0, max_budget - current_spend)
                usage_percent = min(100, (current_spend / max_budget) * 100)

                litellm_team_budget_usd.labels(team_id=team_id, team_alias=team_alias, metric_type='remaining').set(remaining)
                litellm_team_budget_usd.labels(team_id=team_id, team_alias=team_alias, metric_type='usage_percent').set(usage_percent)

    def export_cost_efficiency_metrics(self):
        """Export cost efficiency metrics."""
        litellm_cost_efficiency._metrics.clear()

        query = '''
        SELECT
            COALESCE(sl.team_id, 'no_team') as team_id,
            COALESCE(tt.team_alias, 'no_alias') as team_alias,
            COALESCE(sl.end_user, 'anonymous') as end_user_id,
            COALESCE(eu.alias, COALESCE(sl.end_user, 'anonymous')) as end_user_alias,
            COALESCE(sl.model, 'unknown') as model,
            COALESCE(sl.custom_llm_provider, 'unknown') as provider,
            COALESCE(SUM(sl.spend), 0) as total_spend,
            COALESCE(SUM(sl.total_tokens), 0) as total_tokens
        FROM "LiteLLM_SpendLogs" sl
        LEFT JOIN "LiteLLM_TeamTable" tt ON sl.team_id = tt.team_id
        LEFT JOIN "LiteLLM_EndUserTable" eu ON sl.end_user = eu.user_id
        WHERE sl."startTime" >= NOW() - INTERVAL '24 hours'
            AND sl.spend > 0
            AND sl.total_tokens > 0
        GROUP BY sl.team_id, tt.team_alias, sl.end_user, eu.alias, sl.model, sl.custom_llm_provider
        HAVING SUM(sl.spend) > 0 AND SUM(sl.total_tokens) > 0
        '''

        results = self.execute_query(query)

        for row in results:
            labels = {
                'team_id': str(row['team_id']),
                'team_alias': str(row['team_alias']),
                'end_user_id': str(row['end_user_id']),
                'end_user_alias': str(row['end_user_alias']),
                'model': str(row['model']),
                'provider': str(row['provider'])
            }

            total_spend = float(row['total_spend'])
            total_tokens = float(row['total_tokens'])

            if total_tokens > 0:
                cost_per_token = total_spend / total_tokens
                litellm_cost_efficiency.labels(**labels, metric_type='cost_per_token').set(cost_per_token)

                if total_spend > 0:
                    tokens_per_dollar = total_tokens / total_spend
                    litellm_cost_efficiency.labels(**labels, metric_type='tokens_per_dollar').set(tokens_per_dollar)

    def export_all_metrics(self):
        """Export all metrics"""
        start_time = time.time()

        try:
            # Export main Counter metrics
            self.export_core_metrics()

            # Export additional metrics
            self.export_time_patterns()
            self.export_performance_metrics()
            self.export_team_budget_metrics()
            self.export_cost_efficiency_metrics()

            # Update health metric
            exporter_last_export_timestamp.set(time.time())

            export_time = time.time() - start_time
            if export_time > 1:
                logger.info(f"Metrics exported in {export_time:.2f}s")

        except Exception as e:
            logger.error(f"Export failed: {e}", exc_info=True)
            try:
                self.connect_to_db()
            except:
                pass

    def save_checkpoint(self):
        """Save checkpoint to Redis"""
        self.checkpoint_manager.save_checkpoint(self.last_export_time)

    def shutdown_handler(self, signum, frame):
        """Gracefully handle shutdown and save the final checkpoint."""
        logger.info("=" * 70)
        logger.info("Received shutdown signal, saving final checkpoint...")
        self.save_checkpoint()
        logger.info("✓ Checkpoint saved, shutting down")
        logger.info("=" * 70)
        sys.exit(0)

    def run(self):
        """Main loop for the metrics exporter."""
        logger.info("=" * 70)
        logger.info("🚀 LITELLM METRICS EXPORTER V2.0 (Redis Checkpoint)")
        logger.info("=" * 70)
        logger.info(f"📊 Metrics server: http://localhost:{METRICS_PORT}/metrics")
        logger.info(f"⏱️  Scrape interval: {SCRAPE_INTERVAL}s")
        logger.info(f"💾 Checkpoint interval: {CHECKPOINT_INTERVAL}s")
        logger.info(f"📦 Checkpoint: {'Redis' if self.checkpoint_manager.redis_available else 'Disabled'}")
        logger.info(f"📅 History days: {HISTORY_DAYS}")
        logger.info("=" * 70)

        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGTERM, self.shutdown_handler)
        signal.signal(signal.SIGINT, self.shutdown_handler)

        # Start HTTP server
        start_http_server(METRICS_PORT, registry=registry)

        last_checkpoint_time = time.time()

        while True:
            self.export_all_metrics()

            # Periodic checkpoint
            if time.time() - last_checkpoint_time >= CHECKPOINT_INTERVAL:
                self.save_checkpoint()
                last_checkpoint_time = time.time()

            time.sleep(SCRAPE_INTERVAL)


if __name__ == "__main__":
    exporter = LiteLLMMetricsExporter()
    exporter.run()
