import requests
from bs4 import BeautifulSoup
import os
import json
import hashlib
import time
from urllib.parse import urljoin

# ================= 配置区域 =================
TARGET_URL = "https://www.mec.ca/en/p/featured"
DATA_DIR = "/mnt/mec-special"
DB_FILE = os.path.join(DATA_DIR, "promotions_db.json")

BARK_URLS = [
    "https://api.day.app/SLqpVbfocFSrHMFVK7Ft5k/",
    "https://api.day.app/ScqA3Kv7Ed9XV9E7tLdFEN/"
]
BARK_ICON = "https://www.mec.ca/favicons/apple-touch-icon.png"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
}

# ================= 核心代码 =================

def ensure_dirs():
    if not os.path.exists(DATA_DIR):
        try:
            os.makedirs(DATA_DIR, exist_ok=True)
        except Exception as e:
            print(f"❌ 目录创建失败: {e}", flush=True)

def load_db():
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_db(data):
    try:
        with open(DB_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"❌ 数据库保存失败: {e}", flush=True)

def send_bark(title, content, remote_img_url):
    print(f"🔔 正在推送 Bark: {title}...", flush=True)
    params = {
        "title": f"MEC 新促销: {title}",
        "body": content,
        "icon": BARK_ICON,
        "group": "MEC监控",
        "copy": content
    }
    
    if remote_img_url and remote_img_url.startswith('http'):
        params["image"] = remote_img_url

    for base_url in BARK_URLS:
        try:
            url = base_url if base_url.endswith('/') else base_url + "/"
            requests.post(url, data=params, timeout=5)
        except Exception as e:
            print(f"❌ Bark 发送失败: {e}", flush=True)

def parse_block(block):
    header = block.find(['h1', 'h4'])
    if not header:
        return None
    title = header.get_text(strip=True)

    details_text = ""
    promo_code = "No Code"
    
    details_div = block.find('div', class_=lambda x: x and 'RichTextContainer' in x)
    if details_div:
        paragraphs = [p.get_text(strip=True) for p in details_div.find_all('p')]
        details_text = "\n".join(paragraphs)
        for p_text in paragraphs:
            if "Promo Code" in p_text or "Code:" in p_text:
                parts = p_text.split(":")
                if len(parts) > 1:
                    promo_code = parts[1].strip()

    if "$" not in title and promo_code == "No Code":
        return None

    img_url = ""
    img_tag = block.find('img')
    if img_tag:
        srcset = img_tag.get('srcset', '')
        if srcset:
            try:
                last_candidate = srcset.split(',')[-1].strip()
                potential_url = last_candidate.split(' ')[0]
                if potential_url.startswith('http') or potential_url.startswith('/'):
                    img_url = potential_url
            except:
                pass
        
        if not img_url:
            src = img_tag.get('src', '')
            if src and not src.startswith('data:'):
                img_url = src
        
        if img_url and img_url.startswith('/'):
            img_url = urljoin(TARGET_URL, img_url)

    return {
        "id": hashlib.md5(title.encode('utf-8')).hexdigest(),
        "title": title,
        "details": details_text,
        "code": promo_code,
        "img_url": img_url
    }

def extract_promotions(html):
    soup = BeautifulSoup(html, 'html.parser')
    promos = []
    blocks = []

    hero_blocks = soup.find_all('div', class_=lambda x: x and 'HeroTextBlock' in x)
    for hero in hero_blocks:
        parent = hero.find_parent('div', class_=lambda x: x and 'Hero_heroContainer' in x)
        blocks.append(parent if parent else hero)

    articles = soup.find_all('article')
    blocks.extend(articles)

    seen_ids = set()
    for block in blocks:
        data = parse_block(block)
        if data and data['id'] not in seen_ids:
            seen_ids.add(data['id'])
            promos.append(data)
        
    return promos

def main():
    print(f"🚀 MEC 监控启动 (Debug模式) {time.strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
    ensure_dirs()
    
    try:
        print(f"📡 正在连接 {TARGET_URL} ...", flush=True)
        # 增加超时时间到 30秒，防止网络慢被断开
        resp = requests.get(TARGET_URL, headers=HEADERS, timeout=30)
        print(f"✅ 连接成功! 状态码: {resp.status_code}", flush=True)
        resp.raise_for_status()
    except Exception as e:
        print(f"❌ 网络请求失败 (可能原因: DNS解析失败/被防火墙拦截): {e}", flush=True)
        return

    print("📄 正在解析 HTML...", flush=True)
    current_promos = extract_promotions(resp.text)
    print(f"🔍 解析到有效促销: {len(current_promos)} 个", flush=True)
    
    db = load_db()
    is_first_run = len(db) == 0
    
    if is_first_run:
        print("🔰 首次运行: 初始化数据库...", flush=True)

    new_db = db.copy()
    
    for p in current_promos:
        pid = p['id']
        
        if pid not in db:
            print(f"🆕 发现新活动: {p['title']}", flush=True)
            
            new_db[pid] = {
                "title": p['title'],
                "code": p['code'],
                "img_url": p['img_url'],
                "first_seen": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            
            if not is_first_run:
                short_details = p['details'][:100] + "..." if len(p['details']) > 100 else p['details']
                msg_body = f"Code: {p['code']}\n{short_details}"
                send_bark(p['title'], msg_body, p['img_url'])
        else:
            print(f"💤 已收录: {p['title'][:20]}...", flush=True)

    save_db(new_db)
    print(f"✅ 任务完成。", flush=True)

if __name__ == "__main__":
    main()
