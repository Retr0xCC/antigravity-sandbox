# Create default virtual environment and install Jupyter kernel with scientific math libraries
RUN uv venv /home/vscode/.venv && \
    uv pip install --python /home/vscode/.venv/bin/python \
        ipykernel==6.29.5 \
        jupyterlab==4.3.5 \
        notebook==7.3.2 \
        numpy==2.2.3 \
        scipy==1.15.2 \
        matplotlib==3.10.1 \
        sympy==1.13.3 \
        pandas==2.2.3 && \
    /home/vscode/.venv/bin/python -m ipykernel install --user --name math-labs --display-name "Python (Math Labs)"

# Pre-configure environment variables for seamless interactive use
ENV PATH="/home/vscode/.venv/bin:${PATH}"
ENV VIRTUAL_ENV="/home/vscode/.venv"
