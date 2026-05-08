import os


class Config:
    DB_HOST = os.environ.get("DB_HOST", "db.zta.lab")
    DB_PORT = int(os.environ.get("DB_PORT", 5432))
    DB_NAME = os.environ.get("DB_NAME", "ztaapp")
    DB_USER = os.environ.get("DB_USER", "postgres")
    DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres123!")

    APP_HOST = os.environ.get("APP_HOST", "0.0.0.0")
    APP_PORT = int(os.environ.get("APP_PORT", 8081))

    @classmethod
    def dsn(cls):
        return (
            f"host={cls.DB_HOST} port={cls.DB_PORT} "
            f"dbname={cls.DB_NAME} user={cls.DB_USER} "
            f"password={cls.DB_PASSWORD} connect_timeout=3"
        )
