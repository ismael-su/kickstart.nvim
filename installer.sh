#!/bin/bash
set -e

echo "==> Installing Neovim + dependencies..."
sudo add-apt-repository ppa:neovim-ppa/unstable -y
sudo apt update
sudo apt install -y make gcc ripgrep fd-find tree-sitter-cli unzip git xclip neovim \
  golang nodejs npm python3 python3-pip

echo "==> Adding go/bin to PATH..."
grep -qxF 'export PATH="$PATH:$HOME/go/bin"' ~/.bashrc \
  || echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.bashrc
export PATH="$PATH:$HOME/go/bin"

echo "==> Installing gopls..."
go install golang.org/x/tools/gopls@latest

echo "==> Installing pyright..."
npm install -g pyright

echo "==> Installing Claude CLI..."
npm install -g @anthropic-ai/claude-code

echo "==> Cloning kickstart.nvim..."
git clone https://github.com/ismael-su/kickstart.nvim.git "${XDG_CONFIG_HOME:-$HOME/.config}"/nvim

echo ""
echo "Done! Run 'nvim' to finish plugin installation via Lazy."
echo "Restart your shell or run 'source ~/.bashrc' to reload PATH."
