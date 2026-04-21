{ pkgs, ... }:

{
  home.stateVersion = "25.11";

  # --- zsh ---
  programs.zsh = {
    enable = true;
    autocd = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;
    initContent = ''
      # Completion Styling
      zstyle ':completion:*' auto-description 'specify: %d'
      zstyle ':completion:*' completer _expand _complete _correct _approximate
      zstyle ':completion:*' format 'Completing %d'
      zstyle ':completion:*' group-name '''
      zstyle ':completion:*' menu select=2

      # Integration with dircolors
      # Note: Home Manager's dircolors module will set LS_COLORS
      zstyle ':completion:*:default' list-colors ''${(s.:.)LS_COLORS}

      zstyle ':completion:*' list-colors '''
      zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
      zstyle ':completion:*' matcher-list ''' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
      zstyle ':completion:*' menu select=long
      zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
      zstyle ':completion:*' use-compctl false
      zstyle ':completion:*' verbose true
    '';
    history = {
      size = 50000;
      save = 50000;
      share = true;
      ignoreDups = true;
      ignoreAllDups = true;
    };
    shellAliases = {
      ll = "ls -la";
      la = "ls -A";
      gs = "git status";
      gd = "git diff";
      gl = "git log --oneline -20";
      nr = "sudo nixos-rebuild switch --flake ~/nix#$(if [ \"$(uname -m)\" = aarch64 ]; then echo aarch64; else echo x86_64; fi)";
    };
  };

  # Ensures dircolors is installed and configured
  programs.dircolors = {
    enable = true;
    enableZshIntegration = true;
  };

  # --- starship prompt ---
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$nix_shell$character";
      directory.truncation_length = 3;
      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };
    };
  };

  # --- neovim ---
  programs.neovim = {
    enable = true;
    defaultEditor = false;
    viAlias = true;
    vimAlias = true;
    withRuby = false;
    withPython3 = false;
    plugins = with pkgs.vimPlugins; [
      # treesitter
      (nvim-treesitter.withPlugins (p: [
        p.nix p.bash p.lua p.python p.json p.yaml p.toml p.markdown
        p.c p.cpp p.go p.rust p.javascript p.typescript
      ]))

      # fuzzy finder
      telescope-nvim
      plenary-nvim

      # completion
      nvim-cmp
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
    ];
    initLua = ''
      vim.o.number = true
      vim.o.relativenumber = true
      vim.o.expandtab = true
      vim.o.shiftwidth = 2
      vim.o.tabstop = 2
      vim.o.smartindent = true
      vim.o.clipboard = "unnamedplus"
      vim.o.ignorecase = true
      vim.o.smartcase = true
      vim.o.termguicolors = true
      vim.o.signcolumn = "yes"
      vim.o.updatetime = 250
      vim.g.mapleader = " "

      -- telescope
      local ok_ts, telescope = pcall(require, "telescope.builtin")
      if ok_ts then
        vim.keymap.set("n", "<leader>ff", telescope.find_files)
        vim.keymap.set("n", "<leader>fg", telescope.live_grep)
        vim.keymap.set("n", "<leader>fb", telescope.buffers)
      end

      -- lsp (nvim 0.11+ native API)
      vim.lsp.config("nil_ls", {
        cmd = { "nil" },
        filetypes = { "nix" },
        root_markers = { "flake.nix", ".git" },
      })
      vim.lsp.config("lua_ls", {
        cmd = { "lua-language-server" },
        filetypes = { "lua" },
        root_markers = { ".luarc.json", ".git" },
        settings = { Lua = { diagnostics = { globals = { "vim" } } } },
      })
      vim.lsp.enable({ "nil_ls", "lua_ls" })

      vim.keymap.set("n", "gd", vim.lsp.buf.definition)
      vim.keymap.set("n", "K", vim.lsp.buf.hover)
      vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename)
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action)

      -- completion
      local ok_cmp, cmp = pcall(require, "cmp")
      if ok_cmp then
        cmp.setup({
          sources = cmp.config.sources({
            { name = "nvim_lsp" },
            { name = "buffer" },
            { name = "path" },
          }),
          mapping = cmp.mapping.preset.insert({
            ["<C-Space>"] = cmp.mapping.complete(),
            ["<CR>"] = cmp.mapping.confirm({ select = true }),
            ["<Tab>"] = cmp.mapping.select_next_item(),
            ["<S-Tab>"] = cmp.mapping.select_prev_item(),
          }),
        })
      end
    '';
  };

  # --- git ---
  programs.git = {
    enable = true;
    settings = {
      user.name = "p";
      user.email = "p@localhost";
      pull.rebase = true;
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
    };
  };

  # --- direnv ---
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # LSP servers available in path
  home.packages = with pkgs; [
    nil         # nix lsp
    lua-language-server
  ];
}
