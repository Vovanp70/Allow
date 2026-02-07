# Памятка: сборка static_htdocs

- **Монитор на роутере** отдаётся из содержимого `static_htdocs` (при установке копируется в `/opt/etc/allow/monitor`).
- **После любых правок** в `etc/monitor/templates/` или `etc/monitor/static/` — сразу запускать сборку, не спрашивать:
  ```bash
  cd resources/monitor
  py build_static_htdocs.py
  ```
- Python на этой машине: `py` (не `python`).
- Итог сборки: каталог `static_htdocs/` (HTML + static/). Его копируют на роутер при `monitor.sh install`.
