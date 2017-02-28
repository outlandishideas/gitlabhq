module API
  class Runner < Grape::API
    helpers ::API::Helpers::Runner

    resource :runners do
      desc 'Registers a new Runner' do
        success Entities::RunnerRegistrationDetails
        http_codes [[201, 'Runner was created'], [403, 'Forbidden']]
      end
      params do
        requires :token, type: String, desc: 'Registration token'
        optional :description, type: String, desc: %q(Runner's description)
        optional :info, type: Hash, desc: %q(Runner's metadata)
        optional :locked, type: Boolean, desc: 'Should Runner be locked for current project'
        optional :run_untagged, type: Boolean, desc: 'Should Runner handle untagged jobs'
        optional :tag_list, type: Array[String], desc: %q(List of Runner's tags)
      end
      post '/' do
        attributes = attributes_for_keys [:description, :locked, :run_untagged, :tag_list]

        runner =
          if runner_registration_token_valid?
            # Create shared runner. Requires admin access
            Ci::Runner.create(attributes.merge(is_shared: true))
          elsif project = Project.find_by(runners_token: params[:token])
            # Create a specific runner for project.
            project.runners.create(attributes)
          end

        return forbidden! unless runner

        if runner.id
          runner.update(get_runner_version_from_params)
          present runner, with: Entities::RunnerRegistrationDetails
        else
          not_found!
        end
      end

      desc 'Deletes a registered Runner' do
        http_codes [[204, 'Runner was deleted'], [403, 'Forbidden']]
      end
      params do
        requires :token, type: String, desc: %q(Runner's authentication token)
      end
      delete '/' do
        authenticate_runner!
        Ci::Runner.find_by_token(params[:token]).destroy
      end
    end

    resource :jobs do
      desc 'Request a job' do
        success Entities::JobRequest::Response
      end
      params do
        requires :token, type: String, desc: %q(Runner's authentication token)
        optional :last_update, type: String, desc: %q(Runner's queue last_update token)
        optional :info, type: Hash, desc: %q(Runner's metadata)
      end
      post '/request' do
        authenticate_runner!
        not_found! unless current_runner.active?
        update_runner_info

        if current_runner.is_runner_queue_value_latest?(params[:last_update])
          header 'X-GitLab-Last-Update', params[:last_update]
          Gitlab::Metrics.add_event(:build_not_found_cached)
          return job_not_found!
        end

        new_update = current_runner.ensure_runner_queue_value
        result = ::Ci::RegisterJobService.new(current_runner).execute

        if result.valid?
          if result.build
            Gitlab::Metrics.add_event(:build_found,
                                      project: result.build.project.path_with_namespace)
            present result.build, with: Entities::JobRequest::Response
          else
            Gitlab::Metrics.add_event(:build_not_found)
            header 'X-GitLab-Last-Update', new_update
            job_not_found!
          end
        else
          # We received build that is invalid due to concurrency conflict
          Gitlab::Metrics.add_event(:build_invalid)
          conflict!
        end
      end

      desc 'Updates a job' do
        http_codes [[200, 'Job was updated'], [403, 'Forbidden']]
      end
      params do
        requires :token, type: String, desc: %q(Job's authentication token)
        requires :id, type: Fixnum, desc: %q(Job's ID)
        optional :trace, type: String, desc: %q(Job's full trace)
        optional :state, type: String, desc: %q(Job's status: success, failed)
      end
      put '/:id' do
        job = Ci::Build.find_by_id(params[:id])
        authenticate_job!(job)

        job.update_attributes(trace: params[:trace]) if params[:trace]

        Gitlab::Metrics.add_event(:update_build,
                                  project: job.project.path_with_namespace)

        case params[:state].to_s
        when 'success'
          job.success
        when 'failed'
          job.drop
        end
      end
    end
  end
end
