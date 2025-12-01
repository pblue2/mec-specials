FROM python:3.9-slim

# 设置工作目录
WORKDIR /app

# 安装必要的 Python 库
RUN pip install requests beautifulsoup4

# 将脚本复制到容器中
COPY mec_monitor.py .

# 预先创建数据目录，确保挂载点存在
RUN mkdir -p /mnt/mec-special

# 设置容器启动时默认执行的命令
CMD ["python", "mec_monitor.py"]
