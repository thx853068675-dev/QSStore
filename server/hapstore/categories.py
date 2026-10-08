"""Shared catalog taxonomy; legacy names are accepted only as input aliases."""

CATEGORIES = ("影音", "阅读", "社交", "游戏", "工具", "效率", "开发", "生活")

LEGACY_CATEGORY_ALIASES = {
    "开发工具": "开发",
    "社交通讯": "社交",
    "实用工具": "工具",
    "系统工具": "工具",
    "安全隐私": "工具",
    "其他": "工具",
    "摄影录像": "工具",
    "个性化": "工具",
    "无障碍": "工具",
    "新闻资讯": "阅读",
    "教育": "效率",
    "学习": "效率",
    "办公": "效率",
    "企业应用": "效率",
    "出行导航": "生活",
    "购物": "生活",
    "财务": "生活",
    "健康运动": "生活",
    "医疗健康": "生活",
    "美食菜谱": "生活",
    "居家生活": "生活",
    "育儿母婴": "生活",
    "儿童": "生活",
    "政务民生": "生活",
}


def normalize_category(value: object) -> str:
    if not isinstance(value, str):
        return ""
    value = value.strip()
    return value if value in CATEGORIES else LEGACY_CATEGORY_ALIASES.get(value, "")
