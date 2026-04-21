-- lazy.nvim (recommended: pin to a specific version)
return {
  'rizukirr/droid-nvim',
  tag = 'v0.0.1-beta03',
  ft = { 'kotlin', 'java', 'groovy', 'xml' },
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'mason-org/mason.nvim', -- Recommended for auto-installing LSPs
  },
  opts = {},
  config = function()
    require('droid').setup {
      lsp = {
        enabled = true, -- Master toggle for all LSPs
        jre_path = nil, -- Shared JRE path (auto-detected)

        -- Kotlin LSP (kotlin-lsp)
        kotlin = {
          enabled = true,
          jdk_for_symbol_resolution = nil,
          jvm_args = {},
          root_markers = nil,
          suppress_diagnostics = {}, -- e.g. { "PackageDirectoryMismatch" }
          inlay_hints = {
            enabled = true,
            parameters = true,
            parameters_compiled = true,
            parameters_excluded = false,
            types_property = true,
            types_variable = true,
            function_return = true,
            function_parameter = true,
            lambda_return = true,
            lambda_receivers_parameters = true,
            value_ranges = true,
            kotlin_time = true,
            call_chains = false,
          },
        },

        -- Java LSP (jdtls)
        java = {
          enabled = true,
          jvm_args = {},
          root_markers = nil, -- defaults: gradlew, settings.gradle, AndroidManifest.xml
          suppress_diagnostics = {},
          inlay_hints = {
            enabled = true,
            parameters = true,
          },
        },

        -- Groovy LSP (groovy-language-server)
        groovy = {
          enabled = true,
          root_markers = nil, -- defaults: build.gradle, settings.gradle
        },
      },
      logcat = {
        mode = 'horizontal', -- "horizontal" | "vertical" | "float"
        height = 15,
        filters = {
          package = 'mine', -- "mine" (auto-detect) or specific package
          log_level = 'v', -- v, d, i, w, e, f
        },
      },
      android = {
        android_home = nil, -- override ANDROID_HOME env var
        android_avd_home = nil, -- override ANDROID_AVD_HOME env var
      },
    }
  end,
}
