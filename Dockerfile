# ucie-d2d-toolkit —— 功能验证 + 轻量 DFT 检查的容器化复现（Linux）
# -----------------------------------------------------------------------------
# 覆盖：Verilator lint / CRC 自检 / 主仿真 / AXI 仿真 / UVM 分层验证 / DFT 轻量检查。
# 后端综合/STA/SDF 依赖 sv2v + opensta + openroad，本镜像未内置（apt 无对应包）；
# 本机完整跑通请用 install.sh（macOS/brew 一键装全）或 run_all.sh（全流程）。
#
# 构建与运行：
#   docker build -t ucie-d2d-toolkit .
#   docker run --rm ucie-d2d-toolkit
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        verilator iverilog yosys python3 make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . .

CMD ["sh", "-c", "make lint && make crc && make test && make test-axi && make uvm && make dft"]
