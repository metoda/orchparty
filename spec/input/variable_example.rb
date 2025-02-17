application "web-example" do
  variables do
    var app_var: "app"
    var app_var_overwrite: "app"
    var extra_host: "extra_host"
  end

  service "web" do
    image -> { missing_variable }
    command "bundle exec rails s"
    labels do
      label "com.example.web": "web label"
      label "com.example.overwrite": "web"
    end
  end

  service "db" do
    variables do
      var service_var: "service"
      var app_var_overwrite: "service1"
    end
    variables do
      var app_var_overwrite: "service"
    end
    image "postgres:latest"
    command -> { "ruby #{ context.service.name }" }
    labels do
      label "com.example.db": -> { "#{ service.image } label" }
      label "app_var": -> { app_var }
      label "app_var_overwrite": -> { app_var_overwrite }
      label "application.app_var_overwrite": -> { application.app_var_overwrite }
      label "service_var": -> { context.service_var }
    end
    extra_hosts do
      env -> { extra_host }
    end
  end

  service "lb" do
    image -> { "#{frontend_project}:#{image_tag_frontend}" }

    variables do
      var image_tag_frontend: -> { "tag" }
      var frontend_project: -> { "project" }
      var web_port: 2003
      var lb_config: -> { {
        "port": web_port,
        "tags": ["star_metoda"],
        "fqdns": %w[domain.com]
      } }
    end
    lb_config -> { lb_config }
  end
end
