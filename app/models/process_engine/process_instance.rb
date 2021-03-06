module ProcessEngine
  class ProcessInstance < ActiveRecord::Base
    enum status: { movable: 0, waiting: 1, finished: 2 } # check if required to check for branching

    belongs_to :process_definition
    has_many :process_tasks, dependent: :destroy

    scope :desc, -> { order('id desc') }
    scope :asc, -> { order('id asc') }

    def move_to_next_state(pdn_slug_state, options = {})
      move_to_next_cur_state(pdn_slug_state, [], options)
    end

    def start
      update_attributes!(states: [process_definition.starting_node])
      begin_process_instance
      self
    end

    def process_tasks_by_state_name(state_name)
      process_tasks.by_state(state_name).desc
    end

    def last_process_task_by_state_name(state_name)
      process_tasks_by_state_name(state_name).first
    end

    private

    def begin_process_instance
      ProcessEngine::ProcessTask.spawn_new_task(self, states.first, { assignee: creator })
    end

    def move_to_next_cur_state(cur_state, previous_states = [], options = {})
      current_node = process_definition.schema.node(cur_state)
      schedulable_nodes = current_node.next_schedulable_nodes(options)

      if schedulable_nodes.count == 0
        update!(status: :finished, states: [cur_state]) # finish life cycle
      else
        schedulable_nodes.each do |sn|
          execute_single_next_movable_nodes(cur_state, previous_states, sn)
        end
      end
    end

    def execute_single_next_movable_nodes(cur_state, previous_states, node)
      new_state = node.node_id

      injected_data = ProcessEngine::NodeDataInjection.node_options_data(process_definition.slug, new_state, self)

      # check if node can be computed (e.g. script task, or branching node)
      if ProcessEngine::Schema::Node::COMPUTED_NODE_TYPES.include?(node.node_type)
        move_to_next_cur_state(new_state, previous_states + [cur_state], injected_data)

      elsif node.node_type == ProcessEngine::Schema::Node::NodeType::COMPLEX_GATEWAY

        unless states.include?(new_state)
          update!(states: (states | [new_state]) - ([cur_state] | previous_states))
        else
          # one state has already been reached, and we just need to move forward
          move_to_next_cur_state(new_state, previous_states + [cur_state], injected_data)
        end
      else
        # this node requires action from user
        ProcessEngine::ProcessTask.spawn_new_task(self, new_state, injected_data)
        update!(states: (states | [new_state]) - ([cur_state] | previous_states))
      end
    end
  end
end
