# Create default virtual environment and install Jupyter kernel with scientific math libraries
RUN uv venv /home/vscode/.venv && \
    uv pip install --python /home/vscode/.venv/bin/python \
        ipykernel \
        jupyterlab \
        notebook \
        numpy \
        scipy \
        matplotlib \
        sympy \
        pandas && \
    /home/vscode/.venv/bin/python -m ipykernel install --user --name math-labs --display-name "Python (Math Labs)"

# Pre-configure environment variables for seamless interactive use
ENV PATH="/home/vscode/.venv/bin:${PATH}"
ENV VIRTUAL_ENV="/home/vscode/.venv"
