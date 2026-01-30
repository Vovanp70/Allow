#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Системный монитор для роутера Keenetic
Веб-интерфейс для мониторинга и управления компонентами
"""

from flask import Flask, render_template, jsonify, request
import sys
import os

# Добавляем текущую директорию в путь для импорта config
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config
import paths
from api.system_api import system_api
from api.stubby_api import stubby_api
from api.stubby_family_api import stubby_family_api
from api.dnsmasq_api import dnsmasq_api
from api.dnsmasq_family_api import dnsmasq_family_api
from api.routing_api import routing_api

app = Flask(__name__)
app.config['SECRET_KEY'] = config.SECRET_KEY
# Гарантируем, что служебные директории/файлы существуют
paths.ensure_dirs()

# Регистрация API endpoints
app.register_blueprint(system_api, url_prefix='/api/system')
app.register_blueprint(stubby_api, url_prefix='/api/stubby')
app.register_blueprint(stubby_family_api, url_prefix='/api/stubby-family')
app.register_blueprint(dnsmasq_api, url_prefix='/api/dnsmasq')
app.register_blueprint(dnsmasq_family_api, url_prefix='/api/dnsmasq-family')
app.register_blueprint(routing_api, url_prefix='/api/routing')


@app.route('/')
def index():
    """Главная страница - редирект на dashboard"""
    from flask import redirect, url_for
    return redirect(url_for('dashboard'))


@app.route('/dashboard')
def dashboard():
    """Страница системного монитора"""
    return render_template('dashboard.html')


@app.route('/dnsmasq')
def dnsmasq_page():
    """Страница DNSMASQ full"""
    return render_template('dnsmasq.html')


@app.route('/stubby')
def stubby_page():
    """Страница Stubby"""
    return render_template('stubby.html')


@app.route('/stubby-family')
def stubby_family_page():
    """Страница Stubby Family"""
    return render_template('stubby-family.html')


@app.route('/dnsmasq-family')
def dnsmasq_family_page():
    """Страница DNSMASQ Family"""
    return render_template('dnsmasq-family.html')


@app.route('/routing')
def routing_page():
    """Страница маршрутизации"""
    return render_template('routing.html')


@app.route('/api/auth-token', methods=['GET'])
def get_auth_token():
    """Получить токен аутентификации (только для первого запроса)"""
    # В будущем можно добавить дополнительную проверку
    # Например, проверку что запрос идет с локального IP
    return jsonify({'token': config.AUTH_TOKEN})


@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Not found'}), 404


@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500


if __name__ == '__main__':
    import warnings
    # Подавляем предупреждение Flask о development server (для роутера это нормально)
    warnings.filterwarnings('ignore', message='.*development server.*')
    
    print(f"Starting System Monitor on {config.HOST}:{config.PORT}")
    if config.HOST == '127.0.0.1':
        print("WARNING: Server is bound to localhost only!")
        print("Access will be limited to the router itself.")
        print("To fix: Check network interfaces or set HOST manually in config.py")
    print(f"Auth token: {config.AUTH_TOKEN}")
    
    # Отключаем предупреждение Flask через переменную окружения
    import os
    os.environ['FLASK_ENV'] = 'production'  # Это уберет предупреждение
    
    app.run(
        host=config.HOST,
        port=config.PORT,
        debug=config.DEBUG
    )

