apiVersion: batch/v1
kind: CronJob
metadata:
  name: mec-monitor-job
spec:
  # 调度时间：每30分钟运行一次
  schedule: "*/30 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: mec-monitor
            image: mec-monitor:latest
            # 关键设置：Never 表示强制使用本地镜像，不去 DockerHub 拉取
            imagePullPolicy: Never
            volumeMounts:
            - mountPath: /mnt/mec-special
              name: host-storage
          restartPolicy: OnFailure
          volumes:
          - name: host-storage
            hostPath:
              # 这是您宿主机上的物理路径
              path: /mnt/mec-special
              # 如果目录不存在，K8s 会自动创建
              type: DirectoryOrCreate
