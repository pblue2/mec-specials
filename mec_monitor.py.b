import requests
from bs4 import BeautifulSoup
import os
import json
import hashlib
import time
from urllib.parse import urljoin

# ================= 配置区域 =================
TARGET_URL = "https://www.mec.ca/en/p/featured"

# 数据持久化目录 (容器内路径，映射到宿主机 /mnt/mec-special)
# 必须与 Dockerfile 和 K8s YAML 中的挂载路径一致
DATA_DIR = "/mnt/mec-special"
IMAGES_DIR = os.path.join(DATA_DIR, "images")
DB_FILE = os.path.join(DATA_DIR, "promotions_db.json")

# Bark 通知配置
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
    """确保必要的目录存在"""
    if not os.path.exists(IMAGES_DIR):
        try:
            os.makedirs(IMAGES_DIR, exist_ok=True)
            print(f"✅ 目录已创建: {IMAGES_DIR}")
        except Exception as e:
            print(f"❌ 目录创建失败: {e}")

def load_db():
    """读取历史记录"""
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_db(data):
    """保存记录到 JSON"""
    try:
        with open(DB_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"❌ 数据库保存失败: {e}")

def download_image_local(img_url, file_name):
    """下载图片保存到本地硬盘"""
    save_path = os.path.join(IMAGES_DIR, file_name)
    # 如果文件已存在，跳过下载
    if os.path.exists(save_path):
        return save_path
    
    try:
        resp = requests.get(img_url, headers=HEADERS, timeout=10)
        if resp.status_code == 200:
            with open(save_path, 'wb') as f:
                f.write(resp.content)
            return save_path
    except Exception as e:
        print(f"⚠️ 图片下载失败 ({file_name}): {e}")
    return None

def send_bark(title, content, remote_img_url):
    """发送 Bark 通知"""
    print(f"🔔 发送通知: {title}")
    params = {
        "title": f"MEC 新促销: {title}",
        "body": content,
        "icon": BARK_ICON,
        "image": remote_img_url, # 使用远程 URL 让 Bark 客户端直接加载，速度最快
        "group": "MEC监控",
        "copy": content
    }
    
    for base_url in BARK_URLS:
        try:
            url = base_url if base_url.endswith('/') else base_url + "/"
            requests.post(url, data=params, timeout=5)
        except Exception as e:
            print(f"❌ Bark 发送失败 {base_url[:15]}...: {e}")

def extract_promotions(html):
    """解析 HTML 结构"""
    soup = BeautifulSoup(html, 'html.parser')
    promos = []
    
    # 查找 article 标签
    articles = soup.find_all('article')
    
    # 备用方案：如果找不到 article，查找 main 里的内容
    if not articles:
        main_content = soup.find('main', id='main-content')
        if main_content:
            articles = main_content.find_all('article')

    for art in articles:
        # 提取标题
        h4 = art.find('h4')
        if not h4: continue
        title = h4.get_text(strip=True)
        
        # 生成 ID
        pid = hashlib.md5(title.encode('utf-8')).hexdigest()
        
        # 提取描述和优惠码
        details_text = ""
        promo_code = "无优惠码"
        
        details_div = art.find('div', class_=lambda x: x and 'RichTextContainer' in x)
        if details_div:
            # 获取所有段落文本
            paragraphs = [p.get_text(strip=True) for p in details_div.find_all('p')]
            details_text = "\n".join(paragraphs)
            
            # 简单的优惠码提取逻辑
            for p_text in paragraphs:
                if "Promo Code" in p_text or "Code:" in p_text:
                    parts = p_text.split(":")
                    if len(parts) > 1:
                        promo_code = parts[1].strip()

        # 提取图片 URL
        img_url = ""
        img_tag = art.find('img')
        if img_tag:
            src = img_tag.get('src', '') or img_tag.get('srcset', '').split(' ')[0]
            if src.startswith('/'):
                img_url = urljoin(TARGET_URL, src)
            else:
                img_url = src

        promos.append({
            "id": pid,
            "title": title,
            "details": details_text,
            "code": promo_code,
            "img_url": img_url
        })
        
    return promos

def main():
    print(f"🚀 MEC 监控启动时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    ensure_dirs()
    
    # 1. 获取网页
    try:
        resp = requests.get(TARGET_URL, headers=HEADERS, timeout=20)
        resp.raise_for_status()
    except Exception as e:
        print(f"❌ 网络错误: {e}")
        return

    # 2. 解析
    current_promos = extract_promotions(resp.text)
    print(f"🔍 发现 {len(current_promos)} 个促销活动")
    
    # 3. 加载历史
    db = load_db()
    is_first_run = len(db) == 0
    
    if is_first_run:
        print("🔰 首次运行检测：正在建立基准数据库（不发送通知）。")

    new_db = db.copy()
    
    # 4. 对比逻辑
    for p in current_promos:
        pid = p['id']
        
        # 无论新旧，都把图片保存一份到本地硬盘
        local_filename = f"{pid}.jpg"
        download_image_local(p['img_url'], local_filename)
        
        if pid not in db:
            print(f"🆕 发现新活动: {p['title']}")
            
            new_db[pid] = {
                "title": p['title'],
                "code": p['code'],
                "img_file": local_filename,
                "first_seen": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            
            # 非首次运行才发送通知
            if not is_first_run:
                # 截取详情防止过长
                short_details = p['details'][:100] + "..." if len(p['details']) > 100 else p['details']
                msg_body = f"Code: {p['code']}\n{short_details}"
                send_bark(p['title'], msg_body, p['img_url'])
        else:
            print(f"💤 已存在: {p['title'][:20]}...")

    # 5. 保存
    save_db(new_db)
    print(f"✅ 执行完毕。数据已保存至 {DATA_DIR}")

if __name__ == "__main__":
    main()
