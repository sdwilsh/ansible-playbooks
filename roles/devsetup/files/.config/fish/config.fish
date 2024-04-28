fish_add_path ~/.local/bin
fish_add_path ~/.cargo/bin

if status is-interactive
    # Commands to run in interactive sessions can go here
    starship init fish | source
    fish_vi_key_bindings
    jj util completion fish | source
end
