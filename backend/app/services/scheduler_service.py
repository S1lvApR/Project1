import logging
from datetime import datetime

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from app.database.session import get_db
from app.services.file_cache_service import file_cache_service

logger = logging.getLogger(__name__)


class SchedulerService:
    """定时任务服务"""

    _instance = None
    _scheduler = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._init_scheduler()
        return cls._instance

    def _init_scheduler(self):
        """初始化定时任务调度器"""
        self._scheduler = BackgroundScheduler(timezone="Asia/Shanghai")
        self._register_jobs()

    def _register_jobs(self):
        """注册定时任务"""
        self._scheduler.add_job(
            self._clear_file_cache_daily,
            trigger=CronTrigger(hour=0, minute=0),
            id="clear_file_cache_daily",
            name="每日清理文件缓存",
            replace_existing=True,
        )

    def _clear_file_cache_daily(self):
        """每天0:00清理文件缓存表"""
        try:
            db = next(get_db())
            deleted_count = file_cache_service.clear_all(db)
            logger.info(f"每日文件缓存清理完成，删除 {deleted_count} 条记录")
            print(f"[{datetime.now()}] 每日文件缓存清理完成，删除 {deleted_count} 条记录")
        except Exception as e:
            logger.error(f"每日文件缓存清理失败: {e}")
            print(f"[{datetime.now()}] 每日文件缓存清理失败: {e}")

    def start(self):
        """启动定时任务调度器"""
        if self._scheduler and not self._scheduler.running:
            self._scheduler.start()
            logger.info("定时任务调度器已启动")
            print("定时任务调度器已启动")

    def shutdown(self):
        """关闭定时任务调度器"""
        if self._scheduler and self._scheduler.running:
            self._scheduler.shutdown(wait=True)
            logger.info("定时任务调度器已关闭")
            print("定时任务调度器已关闭")


scheduler_service = SchedulerService()