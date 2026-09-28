#!/usr/bin/env python3
"""本地/服务器统一入口。"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hapstore.app import serve_forever
if __name__ == "__main__":
    serve_forever()
