# Git Workflow для работы с форком LiteLLM

## 📌 Структура remotes

- **origin** → `yshishenya/litellm` (ваш форк)
- **upstream** → `BerriAI/litellm` (оригинальный репозиторий)

## 🔄 Регулярная синхронизация с upstream

### Шаг 1: Обновить main из upstream
```bash
# Переключиться на main
git checkout main

# Стянуть изменения из upstream
git fetch upstream

# Слить изменения из upstream/main в локальный main
git merge upstream/main

# Запушить обновленный main в свой форк
git push origin main
```

**Делайте это раз в неделю или перед началом новой feature!**

## 🚀 Работа над новой фичей

### 1. Создать feature ветку от актуального main
```bash
# Убедиться что main актуальный
git checkout main
git pull upstream main

# Создать feature ветку
git checkout -b feature/monitoring-improvements
```

### 2. Работать в feature ветке
```bash
# Вносить изменения
# Делать коммиты
git add .
git commit -m "feat: add new dashboard"

# Пушить в свой форк
git push origin feature/monitoring-improvements
```

### 3. Если нужно обновить feature ветку с main
```bash
# Находясь в feature ветке
git checkout feature/monitoring-improvements

# Стянуть актуальный main
git fetch upstream
git merge upstream/main

# Или rebase для чистой истории
git rebase upstream/main
```

### 4. После завершения работы
```bash
# Запушить финальные изменения
git push origin feature/monitoring-improvements

# Можно создать Pull Request в upstream (если хотите)
# Или просто держать в своем форке
```

## 🛡️ Безопасность

### ❌ Что НЕ делать:
1. **Не работайте напрямую в main** - всегда создавайте feature ветки
2. **Не коммитьте большие файлы** (>100MB) - используйте .gitignore
3. **Не коммитьте секреты** - SQL дампы, .env файлы, пароли
4. **Не делайте force push в main** (только в feature ветки если нужно)

### ✅ Добавьте в .gitignore:
```bash
# Бэкапы и дампы
backups/
*.sql
*.dump

# Локальные конфиги
.env
*.local

# Временные файлы
*.log
*.tmp
```

## 📝 Полезные команды

### Проверить статус
```bash
git status
git log --oneline -10
```

### Посмотреть изменения
```bash
git diff
git diff main..feature/my-feature
```

### Очистить локальный репозиторий
```bash
git prune
git gc
```

### Создать backup ветку перед опасными операциями
```bash
git branch backup-$(date +%Y%m%d)
```

## 🔥 Быстрая синхронизация (скрипт)

Создайте файл `sync.sh`:
```bash
#!/bin/bash
echo "🔄 Синхронизация с upstream..."
git checkout main
git fetch upstream
git merge upstream/main
git push origin main
echo "✅ Готово! Main обновлен"
```

Сделайте исполняемым:
```bash
chmod +x sync.sh
```

Используйте:
```bash
./sync.sh
```

## 📊 Пример workflow для вашего проекта

```bash
# 1. Синхронизация с upstream (раз в неделю)
./sync.sh

# 2. Создание новой feature ветки
git checkout -b feature/grafana-dashboard-v2

# 3. Работа над дашбордами
# ... редактируем файлы ...
git add grafana/provisioning/dashboards/
git commit -m "feat: improve OpenWebUI dashboard"

# 4. Push в свой форк
git push origin feature/grafana-dashboard-v2

# 5. Продолжение работы (следующий день)
git checkout feature/grafana-dashboard-v2
# ... еще изменения ...
git commit -am "fix: correct percentage calculation"
git push origin feature/grafana-dashboard-v2

# 6. Слить в свой main когда готово
git checkout main
git merge feature/grafana-dashboard-v2
git push origin main

# 7. Удалить feature ветку если больше не нужна
git branch -d feature/grafana-dashboard-v2
git push origin --delete feature/grafana-dashboard-v2
```

## 🎯 Рекомендации

1. **Всегда работайте в feature ветках** - это защищает от конфликтов
2. **Синхронизируйте main регулярно** - не давайте ему отставать
3. **Делайте маленькие коммиты** - легче разобраться в истории
4. **Пишите понятные commit messages** - вы потом скажете спасибо
5. **Создавайте backup ветки** перед сложными операциями (rebase, filter-branch)

## 🆘 Если что-то пошло не так

### Откатить последний коммит
```bash
git reset --soft HEAD~1  # Оставить изменения
git reset --hard HEAD~1  # Удалить изменения
```

### Вернуться к состоянию как в origin/main
```bash
git fetch origin
git reset --hard origin/main
```

### Восстановить из backup ветки
```bash
git checkout backup-20251027
git checkout -b recovery
```
