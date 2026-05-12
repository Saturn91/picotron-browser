local show_pointer_cursor = false

function set_cursor(cursor)
  if cursor == "pointer" then
    if not show_pointer_cursor then
      window({cursor = "pointer"})
      show_pointer_cursor = true
    end
    
  else
    if show_pointer_cursor then
      window({cursor = 1})
      show_pointer_cursor = false
    end
  end
end